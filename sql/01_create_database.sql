/* =====================================================================
   01_create_database.sql
   Creates the GridAnalytics database and its four schemas.

   Layers:
     etl  - pipeline run logging
     stg  - raw data exactly as it arrives from the APIs (all text)
     core - cleaned, typed, normalized tables with keys and constraints
     mart - star schema and views built for Power BI (created later)
   ===================================================================== */

IF DB_ID(N'GridAnalytics') IS NULL
    CREATE DATABASE GridAnalytics;
GO

USE GridAnalytics;
GO

IF SCHEMA_ID(N'etl')  IS NULL EXEC (N'CREATE SCHEMA etl');
IF SCHEMA_ID(N'stg')  IS NULL EXEC (N'CREATE SCHEMA stg');
IF SCHEMA_ID(N'core') IS NULL EXEC (N'CREATE SCHEMA core');
IF SCHEMA_ID(N'mart') IS NULL EXEC (N'CREATE SCHEMA mart');
GO
