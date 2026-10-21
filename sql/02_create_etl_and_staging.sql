/* =====================================================================
   02_create_etl_and_staging.sql
   Pipeline log table + staging tables.

   Staging rule: store everything as text, exactly as the API sent it.
   Type conversion and validation happen when moving data into core,
   so a bad value never makes the download itself fail.
   ===================================================================== */

USE GridAnalytics;
GO

/* ---------- Pipeline run log ---------- */
IF OBJECT_ID(N'etl.load_log', N'U') IS NULL
BEGIN
    CREATE TABLE etl.load_log (
        load_id        INT IDENTITY(1,1) NOT NULL
                       CONSTRAINT pk_load_log PRIMARY KEY,
        dataset        VARCHAR(50)    NOT NULL,
        request_start  VARCHAR(20)    NULL,
        request_end    VARCHAR(20)    NULL,
        started_at     DATETIME2(0)   NOT NULL
                       CONSTRAINT df_load_log_started DEFAULT SYSUTCDATETIME(),
        finished_at    DATETIME2(0)   NULL,
        rows_loaded    INT            NULL,
        status         VARCHAR(20)    NOT NULL
                       CONSTRAINT df_load_log_status DEFAULT 'RUNNING'
                       CONSTRAINT ck_load_log_status
                           CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED')),
        error_message  NVARCHAR(4000) NULL
    );
END
GO

/* ---------- EIA-930 hourly region data (demand, forecast, generation, interchange totals) ---------- */
IF OBJECT_ID(N'stg.eia_region_data', N'U') IS NULL
BEGIN
    CREATE TABLE stg.eia_region_data (
        load_id          INT            NOT NULL,
        period           VARCHAR(20)    NULL,
        respondent       VARCHAR(20)    NULL,
        respondent_name  NVARCHAR(200)  NULL,
        type_code        VARCHAR(10)    NULL,   -- D, DF, NG, TI
        type_name        NVARCHAR(100)  NULL,
        value            VARCHAR(50)    NULL,
        value_units      VARCHAR(50)    NULL,
        loaded_at        DATETIME2(0)   NOT NULL
                         CONSTRAINT df_stg_region_loaded DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX ix_stg_region_load ON stg.eia_region_data (load_id);
END
GO

/* ---------- EIA-930 hourly generation by fuel type ---------- */
IF OBJECT_ID(N'stg.eia_fuel_type_data', N'U') IS NULL
BEGIN
    CREATE TABLE stg.eia_fuel_type_data (
        load_id          INT            NOT NULL,
        period           VARCHAR(20)    NULL,
        respondent       VARCHAR(20)    NULL,
        respondent_name  NVARCHAR(200)  NULL,
        fueltype         VARCHAR(10)    NULL,
        type_name        NVARCHAR(100)  NULL,
        value            VARCHAR(50)    NULL,
        value_units      VARCHAR(50)    NULL,
        loaded_at        DATETIME2(0)   NOT NULL
                         CONSTRAINT df_stg_fuel_loaded DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX ix_stg_fuel_load ON stg.eia_fuel_type_data (load_id);
END
GO

/* ---------- EIA-930 hourly interchange between neighbouring regions ---------- */
IF OBJECT_ID(N'stg.eia_interchange_data', N'U') IS NULL
BEGIN
    CREATE TABLE stg.eia_interchange_data (
        load_id      INT            NOT NULL,
        period       VARCHAR(20)    NULL,
        fromba       VARCHAR(20)    NULL,
        fromba_name  NVARCHAR(200)  NULL,
        toba         VARCHAR(20)    NULL,
        toba_name    NVARCHAR(200)  NULL,
        value        VARCHAR(50)    NULL,
        value_units  VARCHAR(50)    NULL,
        loaded_at    DATETIME2(0)   NOT NULL
                     CONSTRAINT df_stg_interchange_loaded DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX ix_stg_interchange_load ON stg.eia_interchange_data (load_id);
END
GO
