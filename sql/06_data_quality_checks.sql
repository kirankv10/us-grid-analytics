/* =====================================================================
   06_data_quality_checks.sql
   Run after each load to confirm the data looks right.
   Screenshots of these results make a good "Data quality" section
   in the README.
   ===================================================================== */

USE GridAnalytics;
GO

-- 1. Pipeline history: did every batch succeed?
SELECT TOP (20) load_id, dataset, request_start, request_end,
       rows_loaded, status, DATEDIFF(SECOND, started_at, finished_at) AS seconds
FROM   etl.load_log
ORDER BY load_id DESC;

-- 2. Rows per month and dataset
SELECT 'grid_metric' AS dataset, FORMAT(period_utc, 'yyyy-MM') AS month, COUNT(*) AS row_count
FROM   core.hourly_grid_metric GROUP BY FORMAT(period_utc, 'yyyy-MM')
UNION ALL
SELECT 'generation_by_fuel', FORMAT(period_utc, 'yyyy-MM'), COUNT(*)
FROM   core.hourly_generation_by_fuel GROUP BY FORMAT(period_utc, 'yyyy-MM')
ORDER BY dataset, month;

-- 3. Missing hours per balancing authority (expected hours vs. hours present)
WITH bounds AS (
    SELECT MIN(period_utc) AS first_hour, MAX(period_utc) AS last_hour
    FROM   core.hourly_grid_metric
)
SELECT g.ba_code,
       DATEDIFF(HOUR, b.first_hour, b.last_hour) + 1 AS expected_hours,
       COUNT(*)                                      AS present_hours,
       DATEDIFF(HOUR, b.first_hour, b.last_hour) + 1 - COUNT(*) AS missing_hours
FROM   core.hourly_grid_metric AS g
CROSS JOIN bounds AS b
GROUP BY g.ba_code, b.first_hour, b.last_hour
HAVING DATEDIFF(HOUR, b.first_hour, b.last_hour) + 1 - COUNT(*) > 0
ORDER BY missing_hours DESC;

-- 4. Suspicious values: negative or NULL demand
SELECT ba_code,
       SUM(CASE WHEN demand_mwh < 0     THEN 1 ELSE 0 END) AS negative_demand_hours,
       SUM(CASE WHEN demand_mwh IS NULL THEN 1 ELSE 0 END) AS null_demand_hours
FROM   core.hourly_grid_metric
GROUP BY ba_code
HAVING SUM(CASE WHEN demand_mwh < 0 OR demand_mwh IS NULL THEN 1 ELSE 0 END) > 0
ORDER BY negative_demand_hours DESC, null_demand_hours DESC;

-- 5. Fuel codes that arrived without a known group (review and fix in core.fuel_type)
SELECT fuel_code, fuel_name FROM core.fuel_type WHERE fuel_group = 'UNKNOWN';

-- 6. Quick sanity preview: EIA forecast error by region for the latest day
SELECT TOP (15) g.ba_code, b.ba_name,
       SUM(g.demand_mwh)                                         AS actual_mwh,
       SUM(g.demand_forecast_mwh)                                AS forecast_mwh,
       100.0 * SUM(ABS(g.demand_mwh - g.demand_forecast_mwh))
             / NULLIF(SUM(g.demand_mwh), 0)                      AS abs_error_pct
FROM   core.hourly_grid_metric AS g
JOIN   core.balancing_authority AS b ON b.ba_code = g.ba_code
WHERE  g.period_utc >= DATEADD(DAY, -1, (SELECT MAX(period_utc) FROM core.hourly_grid_metric))
  AND  b.is_region = 0
GROUP BY g.ba_code, b.ba_name
ORDER BY abs_error_pct DESC;
