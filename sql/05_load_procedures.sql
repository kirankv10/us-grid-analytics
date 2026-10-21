/* =====================================================================
   05_load_procedures.sql
   Stored procedures that move one staging batch (load_id) into core.

   Each procedure:
     1. registers any new balancing authorities / fuel types it sees
     2. converts text to proper types (TRY_CONVERT -> bad values become NULL)
     3. removes duplicates inside the batch
     4. MERGEs into core, so re-loading the same hours is safe (idempotent)
   The Python pipeline calls these after each staging insert.
   ===================================================================== */

USE GridAnalytics;
GO

/* Aggregate regions published by EIA-930 (everything else is a balancing authority).
   Verify against the current EIA respondent list. */
CREATE OR ALTER PROCEDURE core.usp_flag_regions
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE core.balancing_authority
    SET    is_region = 1
    WHERE  is_region = 0
      AND  ba_code IN ('CAL', 'CAR', 'CENT', 'FLA', 'MIDA', 'MIDW', 'NE',
                       'NY', 'NW', 'SE', 'SW', 'TEN', 'TEX', 'US48');
END
GO

/* ---------- Region data: demand, forecast, net generation, total interchange ---------- */
CREATE OR ALTER PROCEDURE core.usp_load_region_data
    @load_id INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;

    INSERT INTO core.balancing_authority (ba_code, ba_name)
    SELECT s.respondent, MAX(COALESCE(s.respondent_name, s.respondent))
    FROM   stg.eia_region_data AS s
    WHERE  s.load_id = @load_id
      AND  s.respondent IS NOT NULL
      AND  NOT EXISTS (SELECT 1 FROM core.balancing_authority AS b WHERE b.ba_code = s.respondent)
    GROUP BY s.respondent;

    EXEC core.usp_flag_regions;

    WITH cleaned AS (
        SELECT respondent AS ba_code,
               TRY_CONVERT(DATETIME2(0), REPLACE(period, 'T', ' ') + ':00:00', 120) AS period_utc,
               type_code,
               TRY_CONVERT(DECIMAL(14,2), value) AS value_mwh
        FROM   stg.eia_region_data
        WHERE  load_id = @load_id
          AND  respondent IS NOT NULL
    ),
    pivoted AS (
        SELECT ba_code,
               period_utc,
               MAX(CASE WHEN type_code = 'D'  THEN value_mwh END) AS demand_mwh,
               MAX(CASE WHEN type_code = 'DF' THEN value_mwh END) AS demand_forecast_mwh,
               MAX(CASE WHEN type_code = 'NG' THEN value_mwh END) AS net_generation_mwh,
               MAX(CASE WHEN type_code = 'TI' THEN value_mwh END) AS total_interchange_mwh
        FROM   cleaned
        WHERE  period_utc IS NOT NULL
        GROUP BY ba_code, period_utc
    )
    MERGE core.hourly_grid_metric AS t
    USING pivoted AS s
       ON t.ba_code = s.ba_code AND t.period_utc = s.period_utc
    WHEN MATCHED THEN UPDATE SET
         demand_mwh            = COALESCE(s.demand_mwh,            t.demand_mwh),
         demand_forecast_mwh   = COALESCE(s.demand_forecast_mwh,   t.demand_forecast_mwh),
         net_generation_mwh    = COALESCE(s.net_generation_mwh,    t.net_generation_mwh),
         total_interchange_mwh = COALESCE(s.total_interchange_mwh, t.total_interchange_mwh),
         last_load_id          = @load_id
    WHEN NOT MATCHED THEN
         INSERT (ba_code, period_utc, demand_mwh, demand_forecast_mwh,
                 net_generation_mwh, total_interchange_mwh, last_load_id)
         VALUES (s.ba_code, s.period_utc, s.demand_mwh, s.demand_forecast_mwh,
                 s.net_generation_mwh, s.total_interchange_mwh, @load_id);

    COMMIT TRANSACTION;
END
GO

/* ---------- Generation by fuel type ---------- */
CREATE OR ALTER PROCEDURE core.usp_load_fuel_type_data
    @load_id INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;

    INSERT INTO core.balancing_authority (ba_code, ba_name)
    SELECT s.respondent, MAX(COALESCE(s.respondent_name, s.respondent))
    FROM   stg.eia_fuel_type_data AS s
    WHERE  s.load_id = @load_id
      AND  s.respondent IS NOT NULL
      AND  NOT EXISTS (SELECT 1 FROM core.balancing_authority AS b WHERE b.ba_code = s.respondent)
    GROUP BY s.respondent;

    EXEC core.usp_flag_regions;

    -- New fuel codes are registered as UNKNOWN so they never break the load;
    -- review them later and set the correct fuel_group.
    INSERT INTO core.fuel_type (fuel_code, fuel_name)
    SELECT s.fueltype, MAX(COALESCE(s.type_name, s.fueltype))
    FROM   stg.eia_fuel_type_data AS s
    WHERE  s.load_id = @load_id
      AND  s.fueltype IS NOT NULL
      AND  NOT EXISTS (SELECT 1 FROM core.fuel_type AS f WHERE f.fuel_code = s.fueltype)
    GROUP BY s.fueltype;

    WITH cleaned AS (
        SELECT respondent AS ba_code,
               TRY_CONVERT(DATETIME2(0), REPLACE(period, 'T', ' ') + ':00:00', 120) AS period_utc,
               fueltype AS fuel_code,
               TRY_CONVERT(DECIMAL(14,2), value) AS generation_mwh
        FROM   stg.eia_fuel_type_data
        WHERE  load_id = @load_id
          AND  respondent IS NOT NULL
          AND  fueltype IS NOT NULL
    ),
    deduped AS (
        SELECT ba_code, period_utc, fuel_code, MAX(generation_mwh) AS generation_mwh
        FROM   cleaned
        WHERE  period_utc IS NOT NULL
        GROUP BY ba_code, period_utc, fuel_code
    )
    MERGE core.hourly_generation_by_fuel AS t
    USING deduped AS s
       ON t.ba_code = s.ba_code AND t.period_utc = s.period_utc AND t.fuel_code = s.fuel_code
    WHEN MATCHED THEN UPDATE SET
         generation_mwh = s.generation_mwh,
         last_load_id   = @load_id
    WHEN NOT MATCHED THEN
         INSERT (ba_code, period_utc, fuel_code, generation_mwh, last_load_id)
         VALUES (s.ba_code, s.period_utc, s.fuel_code, s.generation_mwh, @load_id);

    COMMIT TRANSACTION;
END
GO

/* ---------- Interchange between neighbouring regions ---------- */
CREATE OR ALTER PROCEDURE core.usp_load_interchange_data
    @load_id INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;

    WITH new_bas AS (
        SELECT fromba AS ba_code, fromba_name AS ba_name
        FROM   stg.eia_interchange_data WHERE load_id = @load_id AND fromba IS NOT NULL
        UNION ALL
        SELECT toba, toba_name
        FROM   stg.eia_interchange_data WHERE load_id = @load_id AND toba IS NOT NULL
    )
    INSERT INTO core.balancing_authority (ba_code, ba_name)
    SELECT n.ba_code, MAX(COALESCE(n.ba_name, n.ba_code))
    FROM   new_bas AS n
    WHERE  NOT EXISTS (SELECT 1 FROM core.balancing_authority AS b WHERE b.ba_code = n.ba_code)
    GROUP BY n.ba_code;

    EXEC core.usp_flag_regions;

    WITH cleaned AS (
        SELECT fromba AS from_ba_code,
               toba   AS to_ba_code,
               TRY_CONVERT(DATETIME2(0), REPLACE(period, 'T', ' ') + ':00:00', 120) AS period_utc,
               TRY_CONVERT(DECIMAL(14,2), value) AS interchange_mwh
        FROM   stg.eia_interchange_data
        WHERE  load_id = @load_id
          AND  fromba IS NOT NULL AND toba IS NOT NULL
          AND  fromba <> toba
    ),
    deduped AS (
        SELECT from_ba_code, to_ba_code, period_utc, MAX(interchange_mwh) AS interchange_mwh
        FROM   cleaned
        WHERE  period_utc IS NOT NULL
        GROUP BY from_ba_code, to_ba_code, period_utc
    )
    MERGE core.hourly_interchange AS t
    USING deduped AS s
       ON t.from_ba_code = s.from_ba_code AND t.to_ba_code = s.to_ba_code AND t.period_utc = s.period_utc
    WHEN MATCHED THEN UPDATE SET
         interchange_mwh = s.interchange_mwh,
         last_load_id    = @load_id
    WHEN NOT MATCHED THEN
         INSERT (from_ba_code, to_ba_code, period_utc, interchange_mwh, last_load_id)
         VALUES (s.from_ba_code, s.to_ba_code, s.period_utc, s.interchange_mwh, @load_id);

    COMMIT TRANSACTION;
END
GO
