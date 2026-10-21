/* =====================================================================
   07_create_star_schema.sql
   Star schema (mart layer) for Power BI.

   Dimensions : mart.dim_date, mart.dim_hour, mart.dim_region, mart.dim_fuel
   Facts      : mart.fact_hourly_grid        (demand, forecast, interchange)
                mart.fact_hourly_generation  (MWh and CO2 by fuel)
   Helpers    : core.ba_time_zone            (region -> time zone)
                core.utc_to_local_hour       (UTC hour -> local hour, per time zone)
   Refresh    : EXEC mart.usp_refresh_star_schema;

   EIA reports every hour in UTC. Facts carry both period_utc and
   period_local, and date_key / hour_key use LOCAL time, so "1 PM in
   California" in Power BI really is 1 PM Pacific (daylight saving included).
   Safe to re-run.
   ===================================================================== */

USE GridAnalytics;
GO

-- Analytics database: keep the transaction log small during big rebuilds.
ALTER DATABASE GridAnalytics SET RECOVERY SIMPLE;
GO

/* =====================================================================
   1. Time zone reference
   Windows time zone names (used by AT TIME ZONE; DST handled automatically).
   VERIFY against the EIA-930 balancing authority reference table, which
   lists each respondent's time zone. Codes not listed here fall back to
   UTC and are flagged with is_time_zone_known = 0 in mart.dim_region.
   ===================================================================== */
IF OBJECT_ID(N'core.ba_time_zone', N'U') IS NULL
BEGIN
    CREATE TABLE core.ba_time_zone (
        ba_code    VARCHAR(20)  NOT NULL CONSTRAINT pk_ba_time_zone PRIMARY KEY,
        time_zone  NVARCHAR(64) NOT NULL
    );
END
GO

MERGE core.ba_time_zone AS t
USING (VALUES
    -- Pacific
    ('CISO', N'Pacific Standard Time'), ('BANC', N'Pacific Standard Time'), ('LDWP', N'Pacific Standard Time'),
    ('TIDC', N'Pacific Standard Time'), ('IID',  N'Pacific Standard Time'), ('BPAT', N'Pacific Standard Time'),
    ('PACW', N'Pacific Standard Time'), ('PGE',  N'Pacific Standard Time'), ('PSEI', N'Pacific Standard Time'),
    ('SCL',  N'Pacific Standard Time'), ('TPWR', N'Pacific Standard Time'), ('AVA',  N'Pacific Standard Time'),
    ('CHPD', N'Pacific Standard Time'), ('DOPD', N'Pacific Standard Time'), ('GCPD', N'Pacific Standard Time'),
    ('NEVP', N'Pacific Standard Time'), ('AVRN', N'Pacific Standard Time'), ('GRID', N'Pacific Standard Time'),
    ('CAL',  N'Pacific Standard Time'), ('NW',   N'Pacific Standard Time'),
    -- Mountain (observes DST)
    ('PACE', N'Mountain Standard Time'), ('PSCO', N'Mountain Standard Time'), ('WACM', N'Mountain Standard Time'),
    ('IPCO', N'Mountain Standard Time'), ('NWMT', N'Mountain Standard Time'), ('WAUW', N'Mountain Standard Time'),
    ('EPE',  N'Mountain Standard Time'), ('PNM',  N'Mountain Standard Time'), ('GWA',  N'Mountain Standard Time'),
    ('WWA',  N'Mountain Standard Time'),
    -- Arizona (no DST)
    ('AZPS', N'US Mountain Standard Time'), ('SRP',  N'US Mountain Standard Time'), ('TEPC', N'US Mountain Standard Time'),
    ('WALC', N'US Mountain Standard Time'), ('DEAA', N'US Mountain Standard Time'), ('HGMA', N'US Mountain Standard Time'),
    ('GRIF', N'US Mountain Standard Time'),
    -- Central
    ('ERCO', N'Central Standard Time'), ('MISO', N'Central Standard Time'), ('SWPP', N'Central Standard Time'),
    ('SPA',  N'Central Standard Time'), ('AECI', N'Central Standard Time'), ('TVA',  N'Central Standard Time'),
    ('AEC',  N'Central Standard Time'), ('TEX',  N'Central Standard Time'), ('CENT', N'Central Standard Time'),
    ('MIDW', N'Central Standard Time'), ('TEN',  N'Central Standard Time'),
    -- Eastern
    ('PJM',  N'Eastern Standard Time'), ('NYIS', N'Eastern Standard Time'), ('ISNE', N'Eastern Standard Time'),
    ('FPL',  N'Eastern Standard Time'), ('FPC',  N'Eastern Standard Time'), ('TEC',  N'Eastern Standard Time'),
    ('JEA',  N'Eastern Standard Time'), ('TAL',  N'Eastern Standard Time'), ('SEC',  N'Eastern Standard Time'),
    ('FMPP', N'Eastern Standard Time'), ('GVL',  N'Eastern Standard Time'), ('HST',  N'Eastern Standard Time'),
    ('NSB',  N'Eastern Standard Time'), ('DUK',  N'Eastern Standard Time'), ('CPLE', N'Eastern Standard Time'),
    ('CPLW', N'Eastern Standard Time'), ('SC',   N'Eastern Standard Time'), ('SCEG', N'Eastern Standard Time'),
    ('LGEE', N'Eastern Standard Time'), ('YAD',  N'Eastern Standard Time'), ('SEPA', N'Eastern Standard Time'),
    ('FLA',  N'Eastern Standard Time'), ('NY',   N'Eastern Standard Time'), ('NE',   N'Eastern Standard Time'),
    ('MIDA', N'Eastern Standard Time'), ('CAR',  N'Eastern Standard Time'), ('US48', N'Eastern Standard Time'),
    -- Regions added after the first load
    ('BHBA', N'Mountain Standard Time'), ('SWPW', N'Mountain Standard Time'), ('SIKE', N'Central Standard Time'),
    ('SOCO', N'Central Standard Time'),  ('SE',   N'Central Standard Time'),  ('SW',   N'US Mountain Standard Time'),
    -- Neighbouring grids in Canada and Mexico (appear in interchange data).
    -- CAN and MEX are national totals spanning several zones and stay on UTC.
    ('AESO', N'Mountain Standard Time'), ('BCHA', N'Pacific Standard Time'),  ('CEN',  N'Pacific Standard Time'),
    ('HQT',  N'Eastern Standard Time'),  ('IESO', N'Eastern Standard Time'),  ('MHEB', N'Central Standard Time'),
    ('NBSO', N'Atlantic Standard Time')
) AS s (ba_code, time_zone)
ON t.ba_code = s.ba_code
WHEN MATCHED THEN UPDATE SET time_zone = s.time_zone
WHEN NOT MATCHED THEN INSERT (ba_code, time_zone) VALUES (s.ba_code, s.time_zone);
GO

IF OBJECT_ID(N'core.utc_to_local_hour', N'U') IS NULL
BEGIN
    CREATE TABLE core.utc_to_local_hour (
        time_zone     NVARCHAR(64) NOT NULL,
        period_utc    DATETIME2(0) NOT NULL,
        period_local  DATETIME2(0) NOT NULL,
        CONSTRAINT pk_utc_to_local_hour PRIMARY KEY (time_zone, period_utc)
    );
END
GO

/* =====================================================================
   2. Dimensions
   ===================================================================== */
IF OBJECT_ID(N'mart.dim_date', N'U') IS NULL
BEGIN
    CREATE TABLE mart.dim_date (
        date_key      INT         NOT NULL CONSTRAINT pk_dim_date PRIMARY KEY,   -- yyyymmdd
        full_date     DATE        NOT NULL CONSTRAINT uq_dim_date_full UNIQUE,
        year          SMALLINT    NOT NULL,
        quarter       TINYINT     NOT NULL,
        month         TINYINT     NOT NULL,
        month_name    VARCHAR(10) NOT NULL,
        month_short   CHAR(3)     NOT NULL,
        year_month    CHAR(7)     NOT NULL,   -- e.g. 2026-07, sorts correctly as text
        day_of_month  TINYINT     NOT NULL,
        day_of_week   TINYINT     NOT NULL,   -- 1 = Monday ... 7 = Sunday
        day_name      VARCHAR(10) NOT NULL,
        is_weekend    BIT         NOT NULL,
        season        VARCHAR(6)  NOT NULL
    );
END
GO

IF OBJECT_ID(N'mart.dim_hour', N'U') IS NULL
BEGIN
    CREATE TABLE mart.dim_hour (
        hour_key      TINYINT     NOT NULL CONSTRAINT pk_dim_hour PRIMARY KEY,   -- 0-23, local time
        hour_label    VARCHAR(5)  NOT NULL,   -- e.g. 1 PM
        day_part      VARCHAR(10) NOT NULL,
        is_evening_peak BIT       NOT NULL    -- 4 PM to 9 PM, typical grid peak
    );

    INSERT INTO mart.dim_hour (hour_key, hour_label, day_part, is_evening_peak)
    SELECT h,
           CASE WHEN h = 0 THEN '12 AM' WHEN h < 12 THEN CONCAT(h, ' AM')
                WHEN h = 12 THEN '12 PM' ELSE CONCAT(h - 12, ' PM') END,
           CASE WHEN h < 6 THEN 'Night' WHEN h < 12 THEN 'Morning'
                WHEN h < 18 THEN 'Afternoon' ELSE 'Evening' END,
           CASE WHEN h BETWEEN 16 AND 20 THEN 1 ELSE 0 END
    FROM (SELECT TOP (24) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS h
          FROM sys.all_objects) AS hours;
END
GO

IF OBJECT_ID(N'mart.dim_region', N'U') IS NULL
BEGIN
    CREATE TABLE mart.dim_region (
        region_key          INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_region PRIMARY KEY,
        ba_code             VARCHAR(20)   NOT NULL CONSTRAINT uq_dim_region_code UNIQUE,
        ba_name             NVARCHAR(200) NOT NULL,
        region_type         VARCHAR(20)   NOT NULL,   -- Balancing authority / Aggregate region
        time_zone           NVARCHAR(64)  NOT NULL,
        is_time_zone_known  BIT           NOT NULL,
        reports_demand      BIT           NOT NULL    -- 0 = generation-only (e.g. YAD)
    );
END
GO

IF OBJECT_ID(N'mart.dim_fuel', N'U') IS NULL
BEGIN
    CREATE TABLE mart.dim_fuel (
        fuel_key        INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_fuel PRIMARY KEY,
        fuel_code       VARCHAR(10)   NOT NULL CONSTRAINT uq_dim_fuel_code UNIQUE,
        fuel_name       NVARCHAR(100) NOT NULL,
        fuel_group      VARCHAR(20)   NOT NULL,
        is_renewable    BIT           NOT NULL,
        is_fossil       BIT           NOT NULL,
        is_storage      BIT           NOT NULL,
        kg_co2_per_mwh  DECIMAL(10,2) NULL
    );
END
GO

/* =====================================================================
   3. Facts
   ===================================================================== */
IF OBJECT_ID(N'mart.fact_hourly_grid', N'U') IS NULL
BEGIN
    CREATE TABLE mart.fact_hourly_grid (
        region_key             INT           NOT NULL CONSTRAINT fk_fgrid_region REFERENCES mart.dim_region (region_key),
        date_key               INT           NOT NULL CONSTRAINT fk_fgrid_date   REFERENCES mart.dim_date (date_key),
        hour_key               TINYINT       NOT NULL CONSTRAINT fk_fgrid_hour   REFERENCES mart.dim_hour (hour_key),
        period_utc             DATETIME2(0)  NOT NULL,
        period_local           DATETIME2(0)  NOT NULL,
        demand_mwh             DECIMAL(14,2) NULL,
        demand_forecast_mwh    DECIMAL(14,2) NULL,
        forecast_error_mwh     DECIMAL(14,2) NULL,   -- forecast - actual (positive = over-forecast)
        net_generation_mwh     DECIMAL(14,2) NULL,
        total_interchange_mwh  DECIMAL(14,2) NULL,   -- positive = net export
        CONSTRAINT pk_fact_hourly_grid PRIMARY KEY (region_key, period_utc)
    );
    CREATE INDEX ix_fgrid_date ON mart.fact_hourly_grid (date_key);
END
GO

IF OBJECT_ID(N'mart.fact_hourly_generation', N'U') IS NULL
BEGIN
    CREATE TABLE mart.fact_hourly_generation (
        region_key      INT           NOT NULL CONSTRAINT fk_fgen_region REFERENCES mart.dim_region (region_key),
        fuel_key        INT           NOT NULL CONSTRAINT fk_fgen_fuel   REFERENCES mart.dim_fuel (fuel_key),
        date_key        INT           NOT NULL CONSTRAINT fk_fgen_date   REFERENCES mart.dim_date (date_key),
        hour_key        TINYINT       NOT NULL CONSTRAINT fk_fgen_hour   REFERENCES mart.dim_hour (hour_key),
        period_utc      DATETIME2(0)  NOT NULL,
        period_local    DATETIME2(0)  NOT NULL,
        generation_mwh  DECIMAL(14,2) NULL,   -- negative for storage while charging
        co2_kg          DECIMAL(18,2) NULL,   -- positive generation x emission factor
        CONSTRAINT pk_fact_hourly_generation PRIMARY KEY (region_key, fuel_key, period_utc)
    );
    CREATE INDEX ix_fgen_date ON mart.fact_hourly_generation (date_key);
END
GO

/* =====================================================================
   4. Refresh procedure
   Dimensions are MERGEd (keys stay stable); facts are fully rebuilt.
   Run after each data load:  EXEC mart.usp_refresh_star_schema;
   ===================================================================== */
CREATE OR ALTER PROCEDURE mart.usp_refresh_star_schema
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @first DATE, @last DATE;
    SELECT @first = CAST(MIN(period_utc) AS DATE), @last = CAST(MAX(period_utc) AS DATE)
    FROM core.hourly_grid_metric;

    IF @first IS NULL
    BEGIN
        RAISERROR('core.hourly_grid_metric is empty - load data first.', 16, 1);
        RETURN;
    END

    /* ---- dim_date: whole calendar years covering the data ---- */
    DECLARE @start DATE = DATEFROMPARTS(YEAR(@first), 1, 1),
            @end   DATE = DATEFROMPARTS(YEAR(@last), 12, 31);

    WITH n AS (
        SELECT TOP (DATEDIFF(DAY, @start, @end) + 1)
               ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
        FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
    ),
    d AS (
        SELECT DATEADD(DAY, i, @start) AS dt,
               ((DATEPART(WEEKDAY, DATEADD(DAY, i, @start)) + @@DATEFIRST - 2) % 7) + 1 AS dow
        FROM n
    )
    INSERT INTO mart.dim_date (date_key, full_date, year, quarter, month, month_name, month_short,
                               year_month, day_of_month, day_of_week, day_name, is_weekend, season)
    SELECT YEAR(dt) * 10000 + MONTH(dt) * 100 + DAY(dt),
           dt, YEAR(dt), DATEPART(QUARTER, dt), MONTH(dt),
           CHOOSE(MONTH(dt), 'January','February','March','April','May','June',
                  'July','August','September','October','November','December'),
           CHOOSE(MONTH(dt), 'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'),
           CONCAT(YEAR(dt), '-', RIGHT(CONCAT('0', MONTH(dt)), 2)),
           DAY(dt), dow,
           CHOOSE(dow, 'Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'),
           CASE WHEN dow >= 6 THEN 1 ELSE 0 END,
           CASE WHEN MONTH(dt) IN (12, 1, 2) THEN 'Winter'
                WHEN MONTH(dt) IN (3, 4, 5)  THEN 'Spring'
                WHEN MONTH(dt) IN (6, 7, 8)  THEN 'Summer'
                ELSE 'Fall' END
    FROM d
    WHERE NOT EXISTS (SELECT 1 FROM mart.dim_date AS x WHERE x.full_date = d.dt);

    /* ---- dim_region ---- */
    MERGE mart.dim_region AS t
    USING (
        SELECT b.ba_code, b.ba_name, b.is_region, z.time_zone,
               CASE WHEN EXISTS (SELECT 1 FROM core.hourly_grid_metric AS g
                                 WHERE g.ba_code = b.ba_code AND g.demand_mwh > 0)
                    THEN 1 ELSE 0 END AS reports_demand
        FROM core.balancing_authority AS b
        LEFT JOIN core.ba_time_zone AS z ON z.ba_code = b.ba_code
    ) AS s
    ON t.ba_code = s.ba_code
    WHEN MATCHED THEN UPDATE SET
         ba_name            = s.ba_name,
         region_type        = CASE WHEN s.is_region = 1 THEN 'Aggregate region' ELSE 'Balancing authority' END,
         time_zone          = COALESCE(s.time_zone, N'UTC'),
         is_time_zone_known = CASE WHEN s.time_zone IS NULL THEN 0 ELSE 1 END,
         reports_demand     = s.reports_demand
    WHEN NOT MATCHED THEN
         INSERT (ba_code, ba_name, region_type, time_zone, is_time_zone_known, reports_demand)
         VALUES (s.ba_code, s.ba_name,
                 CASE WHEN s.is_region = 1 THEN 'Aggregate region' ELSE 'Balancing authority' END,
                 COALESCE(s.time_zone, N'UTC'),
                 CASE WHEN s.time_zone IS NULL THEN 0 ELSE 1 END,
                 s.reports_demand);

    /* ---- dim_fuel (latest emission factor per fuel) ---- */
    MERGE mart.dim_fuel AS t
    USING (
        SELECT f.fuel_code, f.fuel_name, f.fuel_group, e.kg_co2_per_mwh
        FROM core.fuel_type AS f
        OUTER APPLY (SELECT TOP (1) ef.kg_co2_per_mwh
                     FROM core.emission_factor AS ef
                     WHERE ef.fuel_code = f.fuel_code
                     ORDER BY ef.valid_from DESC) AS e
    ) AS s
    ON t.fuel_code = s.fuel_code
    WHEN MATCHED THEN UPDATE SET
         fuel_name      = s.fuel_name,
         fuel_group     = s.fuel_group,
         is_renewable   = CASE WHEN s.fuel_group = 'RENEWABLE' THEN 1 ELSE 0 END,
         is_fossil      = CASE WHEN s.fuel_group = 'FOSSIL'    THEN 1 ELSE 0 END,
         is_storage     = CASE WHEN s.fuel_group = 'STORAGE'   THEN 1 ELSE 0 END,
         kg_co2_per_mwh = s.kg_co2_per_mwh
    WHEN NOT MATCHED THEN
         INSERT (fuel_code, fuel_name, fuel_group, is_renewable, is_fossil, is_storage, kg_co2_per_mwh)
         VALUES (s.fuel_code, s.fuel_name, s.fuel_group,
                 CASE WHEN s.fuel_group = 'RENEWABLE' THEN 1 ELSE 0 END,
                 CASE WHEN s.fuel_group = 'FOSSIL'    THEN 1 ELSE 0 END,
                 CASE WHEN s.fuel_group = 'STORAGE'   THEN 1 ELSE 0 END,
                 s.kg_co2_per_mwh);

    /* ---- UTC -> local hour lookup (convert each hour once per time zone,
            instead of running AT TIME ZONE on millions of fact rows) ---- */
    TRUNCATE TABLE core.utc_to_local_hour;

    WITH hrs AS (
        SELECT DISTINCT period_utc FROM core.hourly_grid_metric
        UNION
        SELECT DISTINCT period_utc FROM core.hourly_generation_by_fuel
    ),
    tz AS (SELECT DISTINCT time_zone FROM mart.dim_region)
    INSERT INTO core.utc_to_local_hour (time_zone, period_utc, period_local)
    SELECT tz.time_zone, h.period_utc,
           CAST((h.period_utc AT TIME ZONE 'UTC') AT TIME ZONE tz.time_zone AS DATETIME2(0))
    FROM hrs AS h
    CROSS JOIN tz;

    /* ---- fact_hourly_grid ---- */
    TRUNCATE TABLE mart.fact_hourly_grid;

    INSERT INTO mart.fact_hourly_grid (region_key, date_key, hour_key, period_utc, period_local,
                                       demand_mwh, demand_forecast_mwh, forecast_error_mwh,
                                       net_generation_mwh, total_interchange_mwh)
    SELECT r.region_key,
           YEAR(m.period_local) * 10000 + MONTH(m.period_local) * 100 + DAY(m.period_local),
           DATEPART(HOUR, m.period_local),
           g.period_utc, m.period_local,
           g.demand_mwh, g.demand_forecast_mwh,
           g.demand_forecast_mwh - g.demand_mwh,
           g.net_generation_mwh, g.total_interchange_mwh
    FROM core.hourly_grid_metric AS g
    JOIN mart.dim_region AS r ON r.ba_code = g.ba_code
    JOIN core.utc_to_local_hour AS m ON m.time_zone = r.time_zone AND m.period_utc = g.period_utc;

    /* ---- fact_hourly_generation ---- */
    TRUNCATE TABLE mart.fact_hourly_generation;

    INSERT INTO mart.fact_hourly_generation (region_key, fuel_key, date_key, hour_key,
                                             period_utc, period_local, generation_mwh, co2_kg)
    SELECT r.region_key, f.fuel_key,
           YEAR(m.period_local) * 10000 + MONTH(m.period_local) * 100 + DAY(m.period_local),
           DATEPART(HOUR, m.period_local),
           g.period_utc, m.period_local,
           g.generation_mwh,
           CASE WHEN g.generation_mwh > 0
                THEN g.generation_mwh * COALESCE(f.kg_co2_per_mwh, 0)
                ELSE 0 END
    FROM core.hourly_generation_by_fuel AS g
    JOIN mart.dim_region AS r ON r.ba_code = g.ba_code
    JOIN mart.dim_fuel   AS f ON f.fuel_code = g.fuel_code
    JOIN core.utc_to_local_hour AS m ON m.time_zone = r.time_zone AND m.period_utc = g.period_utc;
END
GO