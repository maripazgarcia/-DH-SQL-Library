-- Target cities: Ciudad de guatemala, Cuenca, Sylhet (the 3 of the 5 in supply_cities_Q3_KR
-- currently below the 1.05 healthy threshold on rolling_4w_avg_supply_level as of 2026-08-31).
-- Swap the city list in the WHERE clauses below if the KR targets a different 3.
CREATE OR REPLACE TABLE `logistics-data-storage-staging.Maripaz.supply_kr_weighted_4w_tracker` AS

WITH base AS (
  SELECT city_name, date_week, rolling_4w_active_fleet, rolling_4w_required_fleet, data_status
  FROM `logistics-data-storage-staging.Maripaz.supply_cities_Q3_KR`
  WHERE LOWER(city_name) IN ('ciudad de guatemala', 'cuenca', 'sylhet')
),

per_city AS (
  SELECT
    date_week,
    city_name,
    rolling_4w_active_fleet AS active_fleet_4w,
    rolling_4w_required_fleet AS required_fleet_4w,
    ROUND(rolling_4w_active_fleet / rolling_4w_required_fleet, 4) AS weighted_4w_avg_supply_level,
    rolling_4w_active_fleet / rolling_4w_required_fleet > 1.05 AS is_healthy_supply,
    data_status
  FROM base
),

total AS (
  SELECT
    date_week,
    'TOTAL (3 cities)' AS city_name,
    SUM(rolling_4w_active_fleet) AS active_fleet_4w,
    SUM(rolling_4w_required_fleet) AS required_fleet_4w,
    ROUND(SUM(rolling_4w_active_fleet) / SUM(rolling_4w_required_fleet), 4) AS weighted_4w_avg_supply_level,
    SUM(rolling_4w_active_fleet) / SUM(rolling_4w_required_fleet) > 1.05 AS is_healthy_supply,
    CASE WHEN LOGICAL_OR(data_status LIKE 'PROVISIONAL%') THEN 'PROVISIONAL' ELSE 'FINAL' END AS data_status
  FROM base
  GROUP BY date_week
)

SELECT * FROM per_city
UNION ALL
SELECT * FROM total
ORDER BY date_week, city_name
