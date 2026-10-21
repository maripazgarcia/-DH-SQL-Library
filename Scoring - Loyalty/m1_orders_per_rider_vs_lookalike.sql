/*====================================================================
  QUERY: Completed orders per rider — canary vs. look-alike
====================================================================
  PURPOSE:
    Before/after comparison of completed orders per rider for each M1
    canary city against its matched look-alike, on a FIXED rider cohort
    so the result can't be moved by fleet turnover.

  COHORT (the point of this query):
    Only riders with at least one active week in the 12 weeks BEFORE
    launch. Riders who joined after launch are excluded — they have no
    "before", so including them would let a change in who is riding
    masquerade as a change in how they ride.

    Look-alike cities get the same rule, anchored to their canary's
    launch date (they never launch themselves).

  METRIC:
    deliveries = SUM(d.completed_deliveries) per rider-week, averaged
    across rider-weeks. Unweighted: every rider-week counts once, so a
    rider active 12 weeks contributes 12 observations and a rider active
    1 week contributes 1.

  PERIODS:
    before = the 12 complete weeks immediately before launch
    after  = every complete week since launch (the current, partial week
             is always excluded)

    A canary whose rollout_date is still in the future has a cohort and a
    "before" but no "after" — its after columns come back NULL.

  SOURCE:
    Cities, pairings and rollout dates come from
    `logistics-data-storage-staging.Maripaz.canary_lookalike_manifest`.
    Add a city there, not here.

  CREATED: 2026-10-12
====================================================================*/

WITH

manifest AS (
  SELECT country_code, city_id, city_name, city_type, paired_canary
  FROM `logistics-data-storage-staging.Maripaz.canary_lookalike_manifest`
),

-- Each city inherits its CANARY's launch date, look-alikes included.
cities AS (
  SELECT
    m.country_code,
    m.city_id,
    m.city_name,
    m.city_type,
    m.paired_canary,
    c.rollout_date AS launch_date
  FROM manifest m
  JOIN (
    SELECT paired_canary, rollout_date
    FROM `logistics-data-storage-staging.Maripaz.canary_lookalike_manifest`
    WHERE city_type = 'Canary'
  ) c USING (paired_canary)
),

-- Completed orders per rider-week, scoped to the manifest cities and to a
-- window starting 12 weeks before the EARLIEST launch in the manifest.
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
  WHERE r.created_date_local >= (
          SELECT DATE_SUB(MIN(rollout_date), INTERVAL 12 WEEK)
          FROM `logistics-data-storage-staging.Maripaz.canary_lookalike_manifest`
        )
    -- drop the in-progress week: "after" must only contain complete weeks
    AND r.created_date_local < DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY))
  GROUP BY 1, 2, 3, 4
),

-- The fixed cohort: active at least once in the 12 pre-launch weeks.
cohort AS (
  SELECT DISTINCT rw.country_code, rw.city_id, rw.rider_id
  FROM rider_week rw
  JOIN cities c USING (country_code, city_id)
  WHERE rw.week_start >= DATE_SUB(c.launch_date, INTERVAL 12 WEEK)
    AND rw.week_start <  c.launch_date
),

-- Label every cohort rider-week as before / after.
labelled AS (
  SELECT
    c.paired_canary,
    c.city_type,
    c.city_name,
    c.country_code,
    c.city_id,
    c.launch_date,
    rw.rider_id,
    rw.deliveries,
    CASE
      WHEN rw.week_start >= DATE_SUB(c.launch_date, INTERVAL 12 WEEK)
       AND rw.week_start <  c.launch_date                            THEN 'before'
      WHEN rw.week_start >= c.launch_date                            THEN 'after'
    END AS period
  FROM rider_week rw
  JOIN cities c  USING (country_code, city_id)
  JOIN cohort co USING (country_code, city_id, rider_id)
),

city_period AS (
  SELECT
    paired_canary,
    city_type,
    ANY_VALUE(city_name)   AS city_name,
    ANY_VALUE(country_code) AS country_code,
    ANY_VALUE(city_id)     AS city_id,
    ANY_VALUE(launch_date) AS launch_date,
    period,
    COUNT(DISTINCT rider_id)         AS cohort_riders,
    COUNT(*)                         AS rider_weeks,
    ROUND(AVG(deliveries), 2)        AS orders_per_rider_week
  FROM labelled
  WHERE period IS NOT NULL
  GROUP BY paired_canary, city_type, period
),

per_pair AS (
SELECT
  paired_canary                     AS canary,
  ANY_VALUE(launch_date)            AS launch_date,

  -- Canary
  MAX(IF(city_type = 'Canary', city_name, NULL))                                AS canary_city,
  MAX(IF(city_type = 'Canary' AND period = 'before', cohort_riders, NULL))      AS canary_cohort,
  MAX(IF(city_type = 'Canary' AND period = 'before', orders_per_rider_week, NULL)) AS canary_before,
  MAX(IF(city_type = 'Canary' AND period = 'after',  orders_per_rider_week, NULL)) AS canary_after,

  -- Look-alike
  MAX(IF(city_type = 'Look-alike', city_name, NULL))                                AS lookalike_city,
  MAX(IF(city_type = 'Look-alike' AND period = 'before', cohort_riders, NULL))      AS lookalike_cohort,
  MAX(IF(city_type = 'Look-alike' AND period = 'before', orders_per_rider_week, NULL)) AS lookalike_before,
  MAX(IF(city_type = 'Look-alike' AND period = 'after',  orders_per_rider_week, NULL)) AS lookalike_after,

  -- Difference-in-differences: canary shift minus look-alike shift.
  ROUND(
    ( MAX(IF(city_type = 'Canary'     AND period = 'after',  orders_per_rider_week, NULL))
    - MAX(IF(city_type = 'Canary'     AND period = 'before', orders_per_rider_week, NULL)) )
    -
    ( MAX(IF(city_type = 'Look-alike' AND period = 'after',  orders_per_rider_week, NULL))
    - MAX(IF(city_type = 'Look-alike' AND period = 'before', orders_per_rider_week, NULL)) )
  , 2) AS did_orders_per_rider_week

FROM city_period
GROUP BY paired_canary
),

-- Per-city rows, then one pooled row across every launched canary.
--
-- The pooled row is weighted by cohort size: a city contributes in
-- proportion to how many riders it actually put into the cohort, so Al Ahsa
-- (2,490 riders) counts more than Los Banos (485) instead of each city
-- counting once. Weights come from the canary-side "before" cohort — the
-- fixed population the whole comparison is built on — so the same weight
-- applies to before, after and the DiD.
--
-- Unlaunched canaries are excluded from the pooled row (no "after"), but
-- still appear as their own rows above.
combined AS (
SELECT
  canary, launch_date,
  canary_city, canary_cohort, canary_before, canary_after,
  lookalike_city, lookalike_cohort, lookalike_before, lookalike_after,
  -- How far apart the two cities already were before launch, and how far
  -- apart they are now. The DiD is just gap_after - gap_before; seeing both
  -- gaps separately shows whether a positive DiD means the canary pulled
  -- ahead or merely that it started behind and caught up.
  ROUND(canary_before - lookalike_before, 2) AS gap_before,
  ROUND(canary_after  - lookalike_after,  2) AS gap_after,
  did_orders_per_rider_week
FROM per_pair

UNION ALL

SELECT
  'ALL LAUNCHED (weighted)'                                             AS canary,
  NULL                                                                  AS launch_date,
  CONCAT(CAST(COUNT(*) AS STRING), ' canary cities')                    AS canary_city,
  SUM(canary_cohort)                                                    AS canary_cohort,
  ROUND(SUM(canary_before    * canary_cohort) / SUM(canary_cohort), 2)  AS canary_before,
  ROUND(SUM(canary_after     * canary_cohort) / SUM(canary_cohort), 2)  AS canary_after,
  CONCAT(CAST(COUNT(*) AS STRING), ' look-alikes')                      AS lookalike_city,
  SUM(lookalike_cohort)                                                 AS lookalike_cohort,
  ROUND(SUM(lookalike_before * canary_cohort) / SUM(canary_cohort), 2)  AS lookalike_before,
  ROUND(SUM(lookalike_after  * canary_cohort) / SUM(canary_cohort), 2)  AS lookalike_after,
  ROUND(SUM((canary_before - lookalike_before) * canary_cohort) / SUM(canary_cohort), 2)
                                                                        AS gap_before,
  ROUND(SUM((canary_after  - lookalike_after)  * canary_cohort) / SUM(canary_cohort), 2)
                                                                        AS gap_after,
  ROUND(SUM(did_orders_per_rider_week * canary_cohort) / SUM(canary_cohort), 2)
                                                                        AS did_orders_per_rider_week
FROM per_pair
WHERE canary_after IS NOT NULL
)

-- Absolute orders per rider-week, plus the same comparison in relative terms.
--
-- Why both: the absolute DiD understates cities that start from a low base.
-- Kampala averages ~60 orders/rider-week against Abidjan Nord's ~79, so an
-- identical proportional improvement shows up as fewer absolute orders than
-- it would in a high-volume city like Al Ahsa (~91). The relative view
-- removes that, and also neutralises a pre-existing gap between the pair.
--
-- did_pct_points is the difference of two percentage CHANGES, so its unit is
-- percentage points of growth — not a percentage of a percentage. Al Ahsa's
-- +12.5 means it grew 12.5pp faster than Tabuk, not 12.5% more.
SELECT
  canary,
  launch_date,

  -- Absolute (orders per rider per week)
  canary_city,
  canary_cohort,
  canary_before,
  canary_after,
  lookalike_city,
  lookalike_cohort,
  lookalike_before,
  lookalike_after,
  gap_before,
  gap_after,
  did_orders_per_rider_week,

  -- Relative (% change from before to after)
  ROUND(SAFE_DIVIDE(canary_after    - canary_before,    canary_before)    * 100, 1)
    AS canary_pct_change,
  ROUND(SAFE_DIVIDE(lookalike_after - lookalike_before, lookalike_before) * 100, 1)
    AS lookalike_pct_change,
  ROUND(
      SAFE_DIVIDE(canary_after    - canary_before,    canary_before)    * 100
    - SAFE_DIVIDE(lookalike_after - lookalike_before, lookalike_before) * 100
  , 1) AS did_pct_points

FROM combined
ORDER BY launch_date, canary
