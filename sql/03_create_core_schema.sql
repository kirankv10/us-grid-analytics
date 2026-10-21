/* =====================================================================
   03_create_core_schema.sql
   Normalized core layer: typed columns, primary/foreign keys,
   CHECK constraints and indexes for the common join/filter paths.

   Feature map:
     Grid Stress Index       -> hourly_grid_metric, hourly_interchange
     Carbon intensity        -> hourly_generation_by_fuel, fuel_type, emission_factor
     Electricity wastage     -> state_annual_supply (T&D losses),
                                state_retail_sales (prices), curtailment
     Forecast benchmark      -> hourly_grid_metric (demand vs. demand_forecast)
   ===================================================================== */

USE GridAnalytics;
GO

/* ---------- Reference tables ---------- */

IF OBJECT_ID(N'core.balancing_authority', N'U') IS NULL
BEGIN
    CREATE TABLE core.balancing_authority (
        ba_code        VARCHAR(20)   NOT NULL CONSTRAINT pk_balancing_authority PRIMARY KEY,
        ba_name        NVARCHAR(200) NOT NULL,
        is_region      BIT           NOT NULL CONSTRAINT df_ba_is_region DEFAULT 0,  -- 1 = aggregate region (e.g. CAL, TEX, US48)
        first_seen_at  DATETIME2(0)  NOT NULL CONSTRAINT df_ba_first_seen DEFAULT SYSUTCDATETIME()
    );
END
GO

IF OBJECT_ID(N'core.fuel_type', N'U') IS NULL
BEGIN
    CREATE TABLE core.fuel_type (
        fuel_code   VARCHAR(10)   NOT NULL CONSTRAINT pk_fuel_type PRIMARY KEY,
        fuel_name   NVARCHAR(100) NOT NULL,
        fuel_group  VARCHAR(20)   NOT NULL CONSTRAINT df_fuel_group DEFAULT 'UNKNOWN'
                    CONSTRAINT ck_fuel_group
                        CHECK (fuel_group IN ('FOSSIL', 'RENEWABLE', 'NUCLEAR', 'STORAGE', 'OTHER', 'UNKNOWN'))
    );
END
GO

IF OBJECT_ID(N'core.emission_factor', N'U') IS NULL
BEGIN
    CREATE TABLE core.emission_factor (
        fuel_code       VARCHAR(10)   NOT NULL
                        CONSTRAINT fk_emission_fuel REFERENCES core.fuel_type (fuel_code),
        valid_from      DATE          NOT NULL,
        kg_co2_per_mwh  DECIMAL(10,2) NOT NULL CONSTRAINT ck_emission_nonneg CHECK (kg_co2_per_mwh >= 0),
        source          NVARCHAR(200) NOT NULL,
        CONSTRAINT pk_emission_factor PRIMARY KEY (fuel_code, valid_from)
    );
END
GO

IF OBJECT_ID(N'core.state', N'U') IS NULL
BEGIN
    CREATE TABLE core.state (
        state_code  CHAR(2)      NOT NULL CONSTRAINT pk_state PRIMARY KEY,
        state_name  NVARCHAR(50) NOT NULL
    );
END
GO

/* ---------- Hourly grid facts (EIA-930) ---------- */

IF OBJECT_ID(N'core.hourly_grid_metric', N'U') IS NULL
BEGIN
    CREATE TABLE core.hourly_grid_metric (
        ba_code                VARCHAR(20)   NOT NULL
                               CONSTRAINT fk_grid_metric_ba REFERENCES core.balancing_authority (ba_code),
        period_utc             DATETIME2(0)  NOT NULL,
        demand_mwh             DECIMAL(14,2) NULL,
        demand_forecast_mwh    DECIMAL(14,2) NULL,   -- EIA day-ahead forecast (benchmark for our model)
        net_generation_mwh     DECIMAL(14,2) NULL,
        total_interchange_mwh  DECIMAL(14,2) NULL,   -- positive = net export, negative = net import
        last_load_id           INT           NOT NULL,
        CONSTRAINT pk_hourly_grid_metric PRIMARY KEY (ba_code, period_utc)
    );
    CREATE INDEX ix_grid_metric_period
        ON core.hourly_grid_metric (period_utc)
        INCLUDE (demand_mwh, demand_forecast_mwh, net_generation_mwh, total_interchange_mwh);
END
GO

IF OBJECT_ID(N'core.hourly_generation_by_fuel', N'U') IS NULL
BEGIN
    CREATE TABLE core.hourly_generation_by_fuel (
        ba_code         VARCHAR(20)   NOT NULL
                        CONSTRAINT fk_gen_fuel_ba REFERENCES core.balancing_authority (ba_code),
        period_utc      DATETIME2(0)  NOT NULL,
        fuel_code       VARCHAR(10)   NOT NULL
                        CONSTRAINT fk_gen_fuel_fuel REFERENCES core.fuel_type (fuel_code),
        generation_mwh  DECIMAL(14,2) NULL,
        last_load_id    INT           NOT NULL,
        CONSTRAINT pk_hourly_generation_by_fuel PRIMARY KEY (ba_code, period_utc, fuel_code)
    );
    CREATE INDEX ix_gen_fuel_period_fuel
        ON core.hourly_generation_by_fuel (period_utc, fuel_code)
        INCLUDE (generation_mwh);
END
GO

IF OBJECT_ID(N'core.hourly_interchange', N'U') IS NULL
BEGIN
    CREATE TABLE core.hourly_interchange (
        from_ba_code     VARCHAR(20)   NOT NULL
                         CONSTRAINT fk_interchange_from REFERENCES core.balancing_authority (ba_code),
        to_ba_code       VARCHAR(20)   NOT NULL
                         CONSTRAINT fk_interchange_to REFERENCES core.balancing_authority (ba_code),
        period_utc       DATETIME2(0)  NOT NULL,
        interchange_mwh  DECIMAL(14,2) NULL,
        last_load_id     INT           NOT NULL,
        CONSTRAINT pk_hourly_interchange PRIMARY KEY (from_ba_code, to_ba_code, period_utc),
        CONSTRAINT ck_interchange_distinct CHECK (from_ba_code <> to_ba_code)
    );
    CREATE INDEX ix_interchange_period ON core.hourly_interchange (period_utc);
END
GO

/* ---------- Electricity wastage ---------- */

-- Annual supply & disposition per state (EIA State Electricity Profiles).
-- estimated_losses_mwh = transmission & distribution losses.
IF OBJECT_ID(N'core.state_annual_supply', N'U') IS NULL
BEGIN
    CREATE TABLE core.state_annual_supply (
        state_code             CHAR(2)       NOT NULL
                               CONSTRAINT fk_supply_state REFERENCES core.state (state_code),
        year                   SMALLINT      NOT NULL CONSTRAINT ck_supply_year CHECK (year BETWEEN 1990 AND 2100),
        total_disposition_mwh  DECIMAL(16,2) NULL,
        retail_sales_mwh       DECIMAL(16,2) NULL,
        estimated_losses_mwh   DECIMAL(16,2) NULL CONSTRAINT ck_supply_losses CHECK (estimated_losses_mwh >= 0),
        CONSTRAINT pk_state_annual_supply PRIMARY KEY (state_code, year)
    );
END
GO

-- Retail sales and average price per state, year and customer sector.
-- Used to put a dollar value on lost energy.
IF OBJECT_ID(N'core.state_retail_sales', N'U') IS NULL
BEGIN
    CREATE TABLE core.state_retail_sales (
        state_code           CHAR(2)       NOT NULL
                             CONSTRAINT fk_retail_state REFERENCES core.state (state_code),
        year                 SMALLINT      NOT NULL,
        sector_code          VARCHAR(10)   NOT NULL,   -- e.g. RES, COM, IND, ALL
        sales_mwh            DECIMAL(16,2) NULL,
        avg_price_cents_kwh  DECIMAL(8,3)  NULL CONSTRAINT ck_retail_price CHECK (avg_price_cents_kwh >= 0),
        CONSTRAINT pk_state_retail_sales PRIMARY KEY (state_code, year, sector_code)
    );
END
GO

-- Renewable curtailment (clean energy switched off because the grid could not absorb it).
-- Sources: CAISO and ERCOT public reports.
IF OBJECT_ID(N'core.curtailment', N'U') IS NULL
BEGIN
    CREATE TABLE core.curtailment (
        iso_code            VARCHAR(10)   NOT NULL CONSTRAINT ck_curtail_iso CHECK (iso_code IN ('CAISO', 'ERCOT')),
        interval_start_utc  DATETIME2(0)  NOT NULL,
        interval_minutes    SMALLINT      NOT NULL CONSTRAINT ck_curtail_interval CHECK (interval_minutes > 0),
        resource_type       VARCHAR(10)   NOT NULL CONSTRAINT ck_curtail_resource CHECK (resource_type IN ('SOLAR', 'WIND')),
        curtailed_mwh       DECIMAL(14,3) NOT NULL CONSTRAINT ck_curtail_nonneg CHECK (curtailed_mwh >= 0),
        CONSTRAINT pk_curtailment PRIMARY KEY (iso_code, interval_start_utc, resource_type)
    );
END
GO
