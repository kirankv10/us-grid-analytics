USE GridAnalytics;

INSERT INTO core.emission_factor (fuel_code, valid_from, kg_co2_per_mwh, source)
SELECT f.fuel_code, '2020-01-01', 0.00,
       N'APPROXIMATE placeholder - replace with EPA eGRID values'
FROM core.fuel_type AS f
WHERE f.fuel_code IN ('GEO', 'SNB', 'WNB', 'BAT', 'PS', 'OES', 'UES')
  AND NOT EXISTS (SELECT 1 FROM core.emission_factor AS e
                  WHERE e.fuel_code = f.fuel_code AND e.valid_from = '2020-01-01');

SELECT COUNT(*) AS emission_factors FROM core.emission_factor;