/* =====================================================================
   04_seed_reference_data.sql
   Fuel types and starter CO2 emission factors.

   IMPORTANT: the emission factors below are rounded, approximate
   direct-combustion values so the carbon model works end to end.
   Before publishing results, replace them with values from the
   EPA eGRID data and update the `source` column accordingly.
   Safe to re-run (MERGE).
   ===================================================================== */

USE GridAnalytics;
GO

MERGE core.fuel_type AS t
USING (VALUES
    ('COL', N'Coal',         'FOSSIL'),
    ('NG',  N'Natural gas',  'FOSSIL'),
    ('OIL', N'Petroleum',    'FOSSIL'),
    ('NUC', N'Nuclear',      'NUCLEAR'),
    ('WAT', N'Hydro',        'RENEWABLE'),
    ('SUN', N'Solar',        'RENEWABLE'),
    ('WND', N'Wind',         'RENEWABLE'),
    ('OTH', N'Other',        'OTHER')
) AS s (fuel_code, fuel_name, fuel_group)
ON t.fuel_code = s.fuel_code
WHEN MATCHED THEN
    UPDATE SET fuel_name = s.fuel_name, fuel_group = s.fuel_group
WHEN NOT MATCHED THEN
    INSERT (fuel_code, fuel_name, fuel_group) VALUES (s.fuel_code, s.fuel_name, s.fuel_group);
GO

MERGE core.emission_factor AS t
USING (VALUES
    ('COL', CAST('2020-01-01' AS DATE), 1000.00),
    ('NG',  CAST('2020-01-01' AS DATE),  410.00),
    ('OIL', CAST('2020-01-01' AS DATE),  850.00),
    ('NUC', CAST('2020-01-01' AS DATE),    0.00),
    ('WAT', CAST('2020-01-01' AS DATE),    0.00),
    ('SUN', CAST('2020-01-01' AS DATE),    0.00),
    ('WND', CAST('2020-01-01' AS DATE),    0.00)
) AS s (fuel_code, valid_from, kg_co2_per_mwh)
ON t.fuel_code = s.fuel_code AND t.valid_from = s.valid_from
WHEN MATCHED THEN
    UPDATE SET kg_co2_per_mwh = s.kg_co2_per_mwh
WHEN NOT MATCHED THEN
    INSERT (fuel_code, valid_from, kg_co2_per_mwh, source)
    VALUES (s.fuel_code, s.valid_from, s.kg_co2_per_mwh,
            N'APPROXIMATE placeholder - replace with EPA eGRID values');
GO
