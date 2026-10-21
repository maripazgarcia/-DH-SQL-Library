-- Glovo batch usage: active cities, KPI weights, actual rider distribution,
-- and which cities have no Loyalty program set up in the last 3 months
-- Sources:
--   fulfillment-dwh-production.cl._scoring_settings  → KPI weights + configured batch slots
--   fulfillment-dwh-production.cl.rider_kpi          → actual rider batch distribution
-- Billing project: dhub-data-commune
-- Note: gv-it appears in rider_kpi with corrupted batch numbers — exclude from scoring analysis

-- ============================================================
-- QUERY 1: Active Glovo cities with KPI weights (city level)
-- ============================================================
WITH city_names AS (
  SELECT DISTINCT country_code, city_id, MAX(city_name) AS city_name
  FROM `fulfillment-dwh-production.cl.rider_kpi`
  WHERE STARTS_WITH(country_code, 'gv-')
    AND created_date_local >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
  GROUP BY country_code, city_id
),
active_glovo AS (
  SELECT
    ss.country_code,
    ss.city_id,
    cn.city_name,
    s.start_date,
    s.period_duration_in_weeks,
    ROUND(s.kpi_weight_acceptance, 1)              AS w_acceptance,
    ROUND(s.kpi_weight_actual_to_planned_hours, 1) AS w_actual_to_planned_hours,
    ROUND(s.kpi_weight_special_hours, 1)           AS w_special_hours,
    ROUND(s.kpi_weight_no_show, 1)                 AS w_no_show,
    ROUND(s.kpi_weight_utr, 1)                     AS w_utr,
    ROUND(s.kpi_weight_hours, 1)                   AS w_hours,
    ROUND(s.kpi_weight_deliveries, 1)              AS w_deliveries,
    ROUND(s.kpi_weight_late_login, 1)              AS w_late_login,
    ROUND(s.kpi_weight_tenure, 1)                  AS w_tenure,
    ROUND(s.kpi_weight_manual_undispatches, 1)     AS w_manual_undispatches,
    (SELECT COUNT(DISTINCT slot.batch_number)
     FROM UNNEST(ss.shifts_signup) AS slot)        AS configured_batch_count
  FROM `fulfillment-dwh-production.cl._scoring_settings` ss
  LEFT JOIN city_names cn USING (country_code, city_id)
  CROSS JOIN UNNEST(ss.scoring_settings) AS s
  WHERE STARTS_WITH(ss.country_code, 'gv-')
    AND s.is_active = TRUE
)
SELECT *
FROM active_glovo
ORDER BY country_code, city_name;


-- ============================================================
-- QUERY 2: Country-level KPI weight summary (active configs)
-- Shows: avg weight when used + % of cities that enable each KPI
-- ============================================================
WITH active_glovo AS (
  SELECT
    ss.country_code,
    s.kpi_weight_acceptance,
    s.kpi_weight_actual_to_planned_hours,
    s.kpi_weight_special_hours,
    s.kpi_weight_no_show,
    s.kpi_weight_utr,
    s.kpi_weight_hours,
    s.kpi_weight_deliveries,
    s.kpi_weight_late_login,
    s.kpi_weight_tenure,
    s.kpi_weight_manual_undispatches
  FROM `fulfillment-dwh-production.cl._scoring_settings` ss,
  UNNEST(ss.scoring_settings) AS s
  WHERE STARTS_WITH(ss.country_code, 'gv-')
    AND s.is_active = TRUE
)
SELECT
  country_code,
  COUNT(*)                                                                                     AS active_cities,
  -- Acceptance Rate
  ROUND(AVG(IF(kpi_weight_acceptance > 0, kpi_weight_acceptance, NULL)), 1)                   AS avg_w_acceptance,
  ROUND(COUNTIF(kpi_weight_acceptance > 0) * 100.0 / COUNT(*), 0)                            AS pct_cities_acceptance,
  -- Actual-to-Planned Hours
  ROUND(AVG(IF(kpi_weight_actual_to_planned_hours > 0, kpi_weight_actual_to_planned_hours, NULL)), 1) AS avg_w_avp,
  ROUND(COUNTIF(kpi_weight_actual_to_planned_hours > 0) * 100.0 / COUNT(*), 0)               AS pct_cities_avp,
  -- Special Hours
  ROUND(AVG(IF(kpi_weight_special_hours > 0, kpi_weight_special_hours, NULL)), 1)             AS avg_w_special_hours,
  ROUND(COUNTIF(kpi_weight_special_hours > 0) * 100.0 / COUNT(*), 0)                         AS pct_cities_special_hours,
  -- No Show
  ROUND(AVG(IF(kpi_weight_no_show > 0, kpi_weight_no_show, NULL)), 1)                         AS avg_w_no_show,
  ROUND(COUNTIF(kpi_weight_no_show > 0) * 100.0 / COUNT(*), 0)                               AS pct_cities_no_show,
  -- UTR
  ROUND(AVG(IF(kpi_weight_utr > 0, kpi_weight_utr, NULL)), 1)                                 AS avg_w_utr,
  ROUND(COUNTIF(kpi_weight_utr > 0) * 100.0 / COUNT(*), 0)                                   AS pct_cities_utr,
  -- Hours
  ROUND(AVG(IF(kpi_weight_hours > 0, kpi_weight_hours, NULL)), 1)                             AS avg_w_hours,
  ROUND(COUNTIF(kpi_weight_hours > 0) * 100.0 / COUNT(*), 0)                                 AS pct_cities_hours,
  -- Deliveries
  ROUND(AVG(IF(kpi_weight_deliveries > 0, kpi_weight_deliveries, NULL)), 1)                   AS avg_w_deliveries,
  ROUND(COUNTIF(kpi_weight_deliveries > 0) * 100.0 / COUNT(*), 0)                            AS pct_cities_deliveries,
  -- Tenure
  ROUND(AVG(IF(kpi_weight_tenure > 0, kpi_weight_tenure, NULL)), 1)                           AS avg_w_tenure,
  ROUND(COUNTIF(kpi_weight_tenure > 0) * 100.0 / COUNT(*), 0)                                AS pct_cities_tenure,
  -- Late Login
  ROUND(AVG(IF(kpi_weight_late_login > 0, kpi_weight_late_login, NULL)), 1)                   AS avg_w_late_login,
  ROUND(COUNTIF(kpi_weight_late_login > 0) * 100.0 / COUNT(*), 0)                            AS pct_cities_late_login,
  -- Manual Undispatches
  ROUND(AVG(IF(kpi_weight_manual_undispatches > 0, kpi_weight_manual_undispatches, NULL)), 1) AS avg_w_manual_undispatches,
  ROUND(COUNTIF(kpi_weight_manual_undispatches > 0) * 100.0 / COUNT(*), 0)                   AS pct_cities_manual_undispatches
FROM active_glovo
GROUP BY country_code
ORDER BY country_code;


-- ============================================================
-- QUERY 3: Actual rider distribution per batch level per country
-- Last 3 months from rider_kpi (current_batch_number)
-- ============================================================
WITH batch_dist AS (
  SELECT
    country_code,
    current_batch_number,
    COUNT(DISTINCT rider_id) AS rider_count
  FROM `fulfillment-dwh-production.cl.rider_kpi`
  WHERE STARTS_WITH(country_code, 'gv-')
    AND created_date_local >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
    AND current_batch_number IS NOT NULL
    AND current_batch_number BETWEEN 1 AND 20   -- exclude corrupted values (e.g. gv-it anomaly)
  GROUP BY country_code, current_batch_number
),
country_totals AS (
  SELECT country_code, SUM(rider_count) AS total_riders
  FROM batch_dist
  GROUP BY country_code
)
SELECT
  b.country_code,
  ct.total_riders,
  COUNT(DISTINCT b.current_batch_number)                                                       AS distinct_batches_in_use,
  MAX(b.current_batch_number)                                                                   AS max_batch_in_use,
  STRING_AGG(
    FORMAT('B%d:%.1f%%', b.current_batch_number, ROUND(b.rider_count * 100.0 / ct.total_riders, 1))
    ORDER BY b.current_batch_number
  )                                                                                             AS rider_pct_per_batch
FROM batch_dist b
JOIN country_totals ct USING (country_code)
GROUP BY b.country_code, ct.total_riders
ORDER BY b.country_code;


-- ============================================================
-- QUERY 4: Glovo cities with batches but NO Loyalty setup
--           in the last 3 months + avg weekly active riders
-- Note: gv-es (327 cities) and gv-pt (100 cities) have
--       zero loyalty in the whole country.
-- ============================================================
WITH
batch_cities AS (
  SELECT DISTINCT ss.country_code, ss.city_id
  FROM `fulfillment-dwh-production.cl._scoring_settings` ss,
  UNNEST(ss.scoring_settings) AS s
  WHERE STARTS_WITH(ss.country_code, 'gv-')
    AND s.is_active = TRUE
),
-- Countries with a country-wide loyalty cycle in the last 3 months
nationwide_loyalty AS (
  SELECT DISTINCT rlt.country_code
  FROM `fulfillment-dwh-production.cl.rider_loyalty_tiers` rlt,
  UNNEST(rlt.campaigns) AS c
  WHERE STARTS_WITH(rlt.country_code, 'gv-')
    AND rlt.city_id IS NULL
    AND c.cycle_end_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
),
-- Cities with a city-level loyalty cycle in the last 3 months
city_loyalty AS (
  SELECT DISTINCT rlt.country_code, rlt.city_id
  FROM `fulfillment-dwh-production.cl.rider_loyalty_tiers` rlt,
  UNNEST(rlt.campaigns) AS c
  WHERE STARTS_WITH(rlt.country_code, 'gv-')
    AND rlt.city_id IS NOT NULL
    AND c.cycle_end_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
),
-- Avg weekly active riders per city over last 3 months
avg_riders AS (
  SELECT
    country_code,
    city_id,
    MAX(city_name)                   AS city_name,
    ROUND(AVG(weekly_riders), 0)     AS avg_active_riders
  FROM (
    SELECT country_code, city_id, city_name, created_date_local,
      COUNT(DISTINCT rider_id) AS weekly_riders
    FROM `fulfillment-dwh-production.cl.rider_kpi`
    WHERE STARTS_WITH(country_code, 'gv-')
      AND created_date_local >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
    GROUP BY country_code, city_id, city_name, created_date_local
  )
  GROUP BY country_code, city_id
)
SELECT
  b.country_code,
  b.city_id,
  ar.city_name,
  COALESCE(ar.avg_active_riders, 0) AS avg_active_riders
FROM batch_cities b
LEFT JOIN avg_riders ar USING (country_code, city_id)
WHERE
  -- Exclude if there is a country-wide loyalty campaign
  NOT EXISTS (SELECT 1 FROM nationwide_loyalty nl WHERE nl.country_code = b.country_code)
  -- Exclude if the specific city has loyalty
  AND NOT EXISTS (SELECT 1 FROM city_loyalty cl WHERE cl.country_code = b.country_code AND cl.city_id = b.city_id)
  -- Optional: exclude test/fake cities with no riders
  AND COALESCE(ar.avg_active_riders, 0) > 0
  AND LOWER(ar.city_name) NOT LIKE '%fake%'
ORDER BY b.country_code, avg_active_riders DESC;
