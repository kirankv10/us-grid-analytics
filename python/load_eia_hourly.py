"""Load hourly EIA-930 grid data into SQL Server: API -> staging -> core.

Examples
    python load_eia_hourly.py --dataset region --start 2026-09-01 --end 2026-10-01
    python load_eia_hourly.py --dataset all    --start 2026-01-01 --end 2026-10-01 --chunk-days 7

Dates are UTC. --end is exclusive. Each chunk is its own logged batch, so a
failure part-way through only needs that chunk re-run (loads are idempotent).
"""

import argparse
import logging
from datetime import datetime, timedelta

import pyodbc

import config
from eia_client import EIAClient

DATASETS = {
    "region": {
        "route": "electricity/rto/region-data",
        "table": "stg.eia_region_data",
        "columns": ["period", "respondent", "respondent_name",
                    "type_code", "type_name", "value", "value_units"],
        "api_fields": ["period", "respondent", "respondent-name",
                       "type", "type-name", "value", "value-units"],
        "sort": ["period", "respondent", "type"],
        "procedure": "core.usp_load_region_data",
    },
    "fuel": {
        "route": "electricity/rto/fuel-type-data",
        "table": "stg.eia_fuel_type_data",
        "columns": ["period", "respondent", "respondent_name",
                    "fueltype", "type_name", "value", "value_units"],
        "api_fields": ["period", "respondent", "respondent-name",
                       "fueltype", "type-name", "value", "value-units"],
        "sort": ["period", "respondent", "fueltype"],
        "procedure": "core.usp_load_fuel_type_data",
    },
    "interchange": {
        "route": "electricity/rto/interchange-data",
        "table": "stg.eia_interchange_data",
        "columns": ["period", "fromba", "fromba_name",
                    "toba", "toba_name", "value", "value_units"],
        "api_fields": ["period", "fromba", "fromba-name",
                       "toba", "toba-name", "value", "value-units"],
        "sort": ["period", "fromba", "toba"],
        "procedure": "core.usp_load_interchange_data",
    },
}

INSERT_BATCH_SIZE = 10_000
log = logging.getLogger("pipeline")


def date_chunks(start, end, chunk_days):
    """Split [start, end) into consecutive windows of chunk_days."""
    current = start
    while current < end:
        chunk_end = min(current + timedelta(days=chunk_days), end)
        yield current, chunk_end
        current = chunk_end


def build_params(dataset, chunk_start, chunk_end):
    """EIA start/end are inclusive hours, so the last hour is chunk_end - 1h."""
    params = [
        ("frequency", "hourly"),
        ("data[0]", "value"),
        ("start", chunk_start.strftime("%Y-%m-%dT%H")),
        ("end", (chunk_end - timedelta(hours=1)).strftime("%Y-%m-%dT%H")),
    ]
    # A stable sort keeps offset paging from skipping or repeating rows.
    for i, column in enumerate(DATASETS[dataset]["sort"]):
        params += [(f"sort[{i}][column]", column), (f"sort[{i}][direction]", "asc")]
    return params


def to_text(value):
    if value is None or value == "":
        return None
    return str(value)


def start_load(conn, dataset, request_start, request_end):
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO etl.load_log (dataset, request_start, request_end) "
        "OUTPUT INSERTED.load_id VALUES (?, ?, ?)",
        dataset, request_start, request_end,
    )
    load_id = cur.fetchone()[0]
    conn.commit()
    return load_id


def finish_load(conn, load_id, status, rows_loaded=None, error=None):
    cur = conn.cursor()
    cur.execute(
        "UPDATE etl.load_log SET status = ?, rows_loaded = ?, error_message = ?, "
        "finished_at = SYSUTCDATETIME() WHERE load_id = ?",
        status, rows_loaded, (error or "")[:4000] or None, load_id,
    )
    conn.commit()


def insert_staging(conn, dataset, rows, load_id):
    spec = DATASETS[dataset]
    columns = ["load_id"] + spec["columns"]
    sql = (
        f"INSERT INTO {spec['table']} ({', '.join(columns)}) "
        f"VALUES ({', '.join('?' * len(columns))})"
    )
    values = [
        (load_id, *[to_text(row.get(field)) for field in spec["api_fields"]])
        for row in rows
    ]
    cur = conn.cursor()
    cur.fast_executemany = True
    for i in range(0, len(values), INSERT_BATCH_SIZE):
        cur.executemany(sql, values[i:i + INSERT_BATCH_SIZE])
    conn.commit()


def run_chunk(conn, client, dataset, chunk_start, chunk_end):
    params = build_params(dataset, chunk_start, chunk_end)
    request_start, request_end = params[2][1], params[3][1]
    load_id = start_load(conn, dataset, request_start, request_end)
    log.info("[%s] load %d: %s -> %s", dataset, load_id, request_start, request_end)

    try:
        rows = client.fetch_all(DATASETS[dataset]["route"], params)
        insert_staging(conn, dataset, rows, load_id)
        conn.cursor().execute(f"EXEC {DATASETS[dataset]['procedure']} @load_id = ?", load_id)
        conn.commit()
        finish_load(conn, load_id, "SUCCESS", rows_loaded=len(rows))
        log.info("[%s] load %d: %d rows OK", dataset, load_id, len(rows))
    except Exception as exc:
        conn.rollback()
        finish_load(conn, load_id, "FAILED", error=repr(exc))
        log.error("[%s] load %d FAILED: %s", dataset, load_id, exc)
        raise


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dataset", choices=[*DATASETS, "all"], default="all")
    parser.add_argument("--start", required=True, help="UTC start date, YYYY-MM-DD")
    parser.add_argument("--end", required=True, help="UTC end date (exclusive), YYYY-MM-DD")
    parser.add_argument("--chunk-days", type=int, default=7)
    return parser.parse_args()


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    args = parse_args()

    start = datetime.strptime(args.start, "%Y-%m-%d")
    end = datetime.strptime(args.end, "%Y-%m-%d")
    if end <= start:
        raise SystemExit("--end must be after --start")

    datasets = list(DATASETS) if args.dataset == "all" else [args.dataset]
    client = EIAClient(config.EIA_API_KEY)

    with pyodbc.connect(config.sql_connection_string(), autocommit=False) as conn:
        for dataset in datasets:
            for chunk_start, chunk_end in date_chunks(start, end, args.chunk_days):
                run_chunk(conn, client, dataset, chunk_start, chunk_end)

    log.info("Done.")


if __name__ == "__main__":
    main()
