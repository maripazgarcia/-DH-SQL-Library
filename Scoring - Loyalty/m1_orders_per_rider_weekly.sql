/*====================================================================
  QUERY: Completed orders per rider, WEEKLY — canary vs. look-alike
====================================================================
  PURPOSE:
    The week-by-week series behind m1_orders_per_rider_vs_lookalike.sql.
    Same cohort, same metric, one row per canary per week from August
    2026 on — for charting the two cities' trajectories and eyeballing
    whether they moved in parallel before launch.

  COHORT (identical to the before/after query):
    Riders with at least one active week in the 12 weeks BEFORE their
    canary's launch. Look-alike cities use their canary's launch date.
    The cohort is fixed: the same riders are followed every week, so a
    change in the series is a change in behaviour, never a change in who
    is riding.

  IMPORTANT — the Aug 2026 filter is applied to the OUTPUT only:
    The cohort itself still has to be built from the 12 weeks before each
    launch, which for Jazan and Kampala reaches back to May 2026. Those
    weeks are read, used to define the cohort, and then dropped from the
    result. Filtering them earlier would silently shrink the cohort.

  COLUMNS:
    weeks_from_launch  negative = before launch, 0 = launch week
    period             'before' | 'after' (NULL for pre-cohort weeks)
    *_riders_active    cohort riders actually active that week
    *_orders_per_rider average completed orders per active cohort rider
    gap                canary minus look-alike, same week
    *_vs_own_baseline  % vs that city's own 12-week pre-launch average,
                       so both cities start at ~0% and can be compared
                       on one axis regardless of volume

  A canary that hasn't launched yet returns only its pre-launch weeks.

  SOURCE:
    `logistics-data-storage-staging.Maripaz.canary_lookalike_manifest`

  CREATED: 2026-10-12
====================================================================*/

-- Output window starts at the first Monday of August 2026. Kept as a literal
-- rather than a DECLARE so this stays a single statement — a script with a
-- DECLARE doesn't return clean CSV from `bq query` and can't be pasted into
-- the Google Sheets BigQuery connector. Change the date in both places below.

WITH

manifest AS (
  SELECT country_code, city_id, city_name, city_type, paired_canary
  FROM `logistics-data-storage-staging.Maripaz.canary_lookalike_manifest`
),

cities AS (
  SELECT
    m.country_code, m.city_id, m.city_name, m.city_type, m.paired_canary,
    c.rollout_date AS launch_date
  FROM manifest m
  JOIN (
    SELECT paired_canary, rollout_date
    FROM `logistics-data-storage-staging.Maripaz.canary_lookalike_manifest`
    WHERE city_type = 'Canary'
  ) c USING (paired_canary)
),

rider_week AS (
  SELECT
    r.country_code,
    r.city_id,
    DATE_TRUNC(r.created_date_local, WEEK(MONDAY)) AS week_start,
    r.rider_id,
    SUM(d.completed_deliveries) AS deliveries
  FROM `fulfillment-dwh-production.cl.rider_kpi` r,
    UNNEST(r.deliveries) AS d
  INNER JOIN cities cf
    ON r.country_code = cf.country_code AND r.city_id = cf.city_id
  -- reaches back before output_from on purpose: needed to build the cohort
  WHERE r.created_date_local >= (
          SELECT DATE_SUB(MIN(rollout_date), INTERVAL 12 WEEK)
          FROM `logistics-data-storage-staging.Maripaz.canary_lookalike_manifest`
        )
    AND r.created_date_local < DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY))
  GROUP BY 1, 2, 3, 4
),

cohort AS (
  SELECT DISTINCT rw.country_code, rw.city_id, rw.rider_id
  FROM rider_week rw
  JOIN cities c USING (country_code, city_id)
  WHERE rw.week_start >= DATE_SUB(c.launch_date, INTERVAL 12 WEEK)
    AND rw.week_start <  c.launch_date
),

-- One row per city per week, cohort riders only.
city_week AS (
  SELECT
    c.paired_canary,
    c.city_type,
    ANY_VALUE(c.city_name)   AS city_name,
    ANY_VALUE(c.launch_date) AS launch_date,
    rw.week_start,
    COUNT(DISTINCT rw.rider_id) AS riders_active,
    ROUND(AVG(rw.deliveries), 2) AS orders_per_rider
  FROM rider_week rw
  JOIN cities c  USING (country_code, city_id)
  JOIN cohort co USING (country_code, city_id, rider_id)
  GROUP BY c.paired_canary, c.city_type, rw.week_start
),

-- Each city's own pre-launch average, used to index the series to 0%.
baseline AS (
  SELECT
    paired_canary,
    city_type,
    AVG(orders_per_rider) AS pre_avg
  FROM city_week
  WHERE week_start >= DATE_SUB(launch_date, INTERVAL 12 WEEK)
    AND week_start <  launch_date
  GROUP BY paired_canary, city_type
),

per_canary AS (
SELECT
  cw.paired_canary AS canary,
  cw.week_start,
  ANY_VALUE(cw.launch_date) AS launch_date,
  DATE_DIFF(cw.week_start, ANY_VALUE(cw.launch_date), WEEK) AS weeks_from_launch,
  CASE
    WHEN cw.week_start >= DATE_SUB(ANY_VALUE(cw.launch_date), INTERVAL 12 WEEK)
     AND cw.week_start <  ANY_VALUE(cw.launch_date)                     THEN 'before'
    WHEN cw.week_start >= ANY_VALUE(cw.launch_date)                     THEN 'after'
  END AS period,

  -- Canary
  MAX(IF(cw.city_type = 'Canary', cw.city_name, NULL))        AS canary_city,
  MAX(IF(cw.city_type = 'Canary', cw.riders_active, NULL))    AS canary_riders_active,
  MAX(IF(cw.city_type = 'Canary', cw.orders_per_rider, NULL)) AS canary_orders_per_rider,

  -- Look-alike
  MAX(IF(cw.city_type = 'Look-alike', cw.city_name, NULL))        AS lookalike_city,
  MAX(IF(cw.city_type = 'Look-alike', cw.riders_active, NULL))    AS lookalike_riders_active,
  MAX(IF(cw.city_type = 'Look-alike', cw.orders_per_rider, NULL)) AS lookalike_orders_per_rider,

  ROUND(
      MAX(IF(cw.city_type = 'Canary',     cw.orders_per_rider, NULL))
    - MAX(IF(cw.city_type = 'Look-alike', cw.orders_per_rider, NULL))
  , 2) AS gap,

  -- Indexed to each city's own pre-launch average (both start near 0%).
  ROUND(SAFE_DIVIDE(
      MAX(IF(cw.city_type = 'Canary', cw.orders_per_rider, NULL))
    - MAX(IF(cw.city_type = 'Canary', b.pre_avg, NULL)),
      MAX(IF(cw.city_type = 'Canary', b.pre_avg, NULL))) * 100
  , 1) AS canary_vs_own_baseline,
  ROUND(SAFE_DIVIDE(
      MAX(IF(cw.city_type = 'Look-alike', cw.orders_per_rider, NULL))
    - MAX(IF(cw.city_type = 'Look-alike', b.pre_avg, NULL)),
      MAX(IF(cw.city_type = 'Look-alike', b.pre_avg, NULL))) * 100
  , 1) AS lookalike_vs_own_baseline

FROM city_week cw
LEFT JOIN baseline b
  USING (paired_canary, city_type)
WHERE cw.week_start >= DATE '2026-08-03'
GROUP BY cw.paired_canary, cw.week_start
)

-- Per-canary weekly rows, then one weighted total row per week.
--
-- The total covers LAUNCHED canaries only (rollout_date <= today), matching
-- the pooled row in m1_orders_per_rider_vs_lookalike.sql. Bulacan, Batangas
-- and the OM/AE cities still appear as their own rows, but are kept out of
-- the total until they go live.
--
-- Weighting note: each city contributes in proportion to the cohort riders
-- ACTIVE THAT WEEK, so the total is literally total orders / total active
-- riders. That differs slightly from the before/after query, which weights
-- by each city's fixed pre-launch cohort — here the weight moves week to
-- week with who actually rode.
SELECT
  canary, week_start, launch_date, weeks_from_launch, period,
  canary_city, canary_riders_active, canary_orders_per_rider,
  lookalike_city, lookalike_riders_active, lookalike_orders_per_rider,
  gap, canary_vs_own_baseline, lookalike_vs_own_baseline
FROM per_canary

UNION ALL

SELECT
  'ALL LAUNCHED (weighted)' AS canary,
  week_start,
  NULL AS launch_date,
  NULL AS weeks_from_launch,
  NULL AS period,
  CONCAT(CAST(COUNT(*) AS STRING), ' canary cities')          AS canary_city,
  SUM(canary_riders_active)                                   AS canary_riders_active,
  ROUND(SUM(canary_orders_per_rider * canary_riders_active)
        / NULLIF(SUM(canary_riders_active), 0), 2)            AS canary_orders_per_rider,
  CONCAT(CAST(COUNT(*) AS STRING), ' look-alikes')            AS lookalike_city,
  SUM(lookalike_riders_active)                                AS lookalike_riders_active,
  ROUND(SUM(lookalike_orders_per_rider * lookalike_riders_active)
        / NULLIF(SUM(lookalike_riders_active), 0), 2)         AS lookalike_orders_per_rider,
  ROUND( SUM(canary_orders_per_rider * canary_riders_active)
         / NULLIF(SUM(canary_riders_active), 0)
       - SUM(lookalike_orders_per_rider * lookalike_riders_active)
         / NULLIF(SUM(lookalike_riders_active), 0), 2)        AS gap,
  ROUND(SUM(canary_vs_own_baseline * canary_riders_active)
        / NULLIF(SUM(canary_riders_active), 0), 1)            AS canary_vs_own_baseline,
  ROUND(SUM(lookalike_vs_own_baseline * lookalike_riders_active)
        / NULLIF(SUM(lookalike_riders_active), 0), 1)         AS lookalike_vs_own_baseline
FROM per_canary
WHERE launch_date <= CURRENT_DATE()
GROUP BY week_start

ORDER BY canary, week_start
