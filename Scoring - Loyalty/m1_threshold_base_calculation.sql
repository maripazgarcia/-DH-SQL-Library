-- Table: logistics-data-storage-staging.maripaz.m1_threshold_base_calculation
-- Purpose: Flat weekly rider KPI data — base table for the M1 Threshold Dashboard
-- Partition: week_start | Cluster: city_id, country_code
-- Schedule: weekly (rolling 1-year window auto-maintained by DATE_SUB filter)
-- Validated: 2026-06-04

CREATE OR REPLACE TABLE `logistics-data-storage-staging.maripaz.m1_threshold_base_calculation`
PARTITION BY week_start
CLUSTER BY city_id, country_code
AS

WITH city_names AS (
  SELECT DISTINCT city_id, city_name, country_code
  FROM `fulfillment-dwh-production.cl.rider_kpi`
  WHERE city_id IS NOT NULL AND city_name IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY city_id, country_code ORDER BY city_id) = 1
),

scoring_flat AS (
  SELECT
    s.employee_id                                                                                          AS rider_id,
    s.city_id,
    s.country                                                                                              AS country_code,
    s.region,
    s.batch                                                                                                AS existing_batch,
    s.newbie,
    DATE(s.start_at)                                                                                       AS week_start,
    DATE(s.end_at)                                                                                         AS week_end,
    s.created_date,
    MAX(CASE WHEN JSON_VALUE(kpi,'$.name')='ACCEPTANCE'              THEN CAST(JSON_VALUE(kpi,'$.absolute_value') AS FLOAT64) END) AS acceptance_rate,
    MAX(CASE WHEN JSON_VALUE(kpi,'$.name')='ACTUAL_TO_PLANNED_HOURS' THEN CAST(JSON_VALUE(kpi,'$.absolute_value') AS FLOAT64) END) AS avp_hours,
    MAX(CASE WHEN JSON_VALUE(kpi,'$.name')='DELIVERIES'              THEN CAST(JSON_VALUE(kpi,'$.absolute_value') AS FLOAT64) END) AS deliveries,
    MAX(CASE WHEN JSON_VALUE(kpi,'$.name')='HOURS'                   THEN CAST(JSON_VALUE(kpi,'$.absolute_value') AS FLOAT64) END) AS hours,
    MAX(CASE WHEN JSON_VALUE(kpi,'$.name')='SPECIAL_HOURS'           THEN CAST(JSON_VALUE(kpi,'$.absolute_value') AS FLOAT64) END) AS special_hours,
    MAX(CASE WHEN JSON_VALUE(kpi,'$.name')='UTR'                     THEN CAST(JSON_VALUE(kpi,'$.absolute_value') AS FLOAT64) END) AS utr,
    MAX(CASE WHEN JSON_VALUE(kpi,'$.name')='NO_SHOW'                 THEN CAST(JSON_VALUE(kpi,'$.absolute_value') AS FLOAT64) END) AS no_show,
    MAX(CASE WHEN JSON_VALUE(kpi,'$.name')='LATE_LOGIN'              THEN CAST(JSON_VALUE(kpi,'$.absolute_value') AS FLOAT64) END) AS late_login,
    MAX(CASE WHEN JSON_VALUE(kpi,'$.name')='ACCEPTANCE'              THEN CAST(JSON_VALUE(kpi,'$.weight') AS FLOAT64) END)         AS w_acceptance,
    MAX(CASE WHEN JSON_VALUE(kpi,'$.name')='ACTUAL_TO_PLANNED_HOURS' THEN CAST(JSON_VALUE(kpi,'$.weight') AS FLOAT64) END)         AS w_avp_hours,
    MAX(CASE WHEN JSON_VALUE(kpi,'$.name')='DELIVERIES'              THEN CAST(JSON_VALUE(kpi,'$.weight') AS FLOAT64) END)         AS w_deliveries,
    MAX(CASE WHEN JSON_VALUE(kpi,'$.name')='HOURS'                   THEN CAST(JSON_VALUE(kpi,'$.weight') AS FLOAT64) END)         AS w_hours,
    MAX(CASE WHEN JSON_VALUE(kpi,'$.name')='SPECIAL_HOURS'           THEN CAST(JSON_VALUE(kpi,'$.weight') AS FLOAT64) END)         AS w_special_hours,
    MAX(CASE WHEN JSON_VALUE(kpi,'$.name')='UTR'                     THEN CAST(JSON_VALUE(kpi,'$.weight') AS FLOAT64) END)         AS w_utr,
    MAX(CASE WHEN JSON_VALUE(kpi,'$.name')='NO_SHOW'                 THEN CAST(JSON_VALUE(kpi,'$.weight') AS FLOAT64) END)         AS w_no_show,
    MAX(CASE WHEN JSON_VALUE(kpi,'$.name')='LATE_LOGIN'              THEN CAST(JSON_VALUE(kpi,'$.weight') AS FLOAT64) END)         AS w_late_login
  FROM `fulfillment-dwh-production.dl.rooster_scoring_score` s, UNNEST(s.values) AS kpi
  WHERE s.created_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
    AND ARRAY_LENGTH(s.values) > 0
    AND s.country != 'de2'
  GROUP BY
    rider_id, city_id, country_code, region, existing_batch, newbie,
    week_start, week_end, created_date
)

SELECT
  sf.*,
  cn.city_name,
  CASE
    WHEN sf.country_code IN ('bd','hk','kh','la','mm','my','ph','pk','sg','tw','at','ca','de','fi','no','se','sk','tr','t3','cz','hu','vn') THEN 'Pandora'
    WHEN sf.country_code IN ('ae','bh','eg','iq','jo','kw','om','qa') THEN 'Talabat'
    WHEN sf.country_code = 'sa'                                        THEN 'Hungerstation'
    WHEN sf.country_code IN ('ar','bo','cl','cr','do','ec','gt','hn','ni','py','pe','sv','uy','ve','pa') THEN 'PedidosYa'
    WHEN STARTS_WITH(sf.country_code, 'gv-')                          THEN 'Glovo'
    ELSE 'Other'
  END AS brand
FROM scoring_flat sf
LEFT JOIN city_names cn USING (city_id, country_code)
