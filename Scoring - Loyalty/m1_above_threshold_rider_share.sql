/*=======================================================
  MILESTONE 1 METRIC: "Above-Threshold Rider Share"
  =======================================================
  Measures the % of active riders whose 4-week rolling
  average for Acceptance Rate (AR) and Plan vs. Actual
  Hours (AvP) exceeds the city-level p75 benchmark.

  The p75 benchmark is FIXED — computed once from the
  last 3 months of data. Post-launch, it does not change.
  An increasing % over time = Milestone 1 is working.

  HOW TO READ THE OUTPUT:
    - benchmark_ar_p75_pct / benchmark_avp_p75_pct:
        The frozen benchmark values. Do not recalculate
        after launch.
    - pct_above_both:
        The headline Milestone 1 success metric.
    - pct_above_ar / pct_above_avp:
        Per-KPI breakdown to diagnose which KPI is
        the bottleneck city by city.
    - The most recent stable week = Day-0 baseline
        before launch.

  SOURCE TABLE: fulfillment-dwh-production.cl.rider_kpi
  BILLING PROJECT: dhub-data-commune

  CANARY SCOPE:
    SA   Jazan             (Hungerstation — confirmed)
    EC   Guayaquil, Quito  (PedidosYa — top 2 cities)
    PH   Manila, South mm  (Pandora — top 2 cities)
    AE   Al ain, Ajman     (Talabat UAE — confirmed)
    OM   Jalan             (Talabat Oman — confirmed)
    gv-* All markets       (Glovo — all markets pooled)

  DAY-0 BASELINES (week of 2026-05-04):
    Hungerstation – Jazan      7.0%  (AR p75=98.3%, AvP p75=98.6%)
    PedidosYa – Guayaquil      5.8%  (AR p75=100.0%, AvP p75=102.9%)
    PedidosYa – Quito          7.8%  (AR p75=100.0%, AvP p75=105.4%)
    Pandora – Manila           4.4%  (AR p75=99.0%, AvP p75=82.3%)
    Pandora – South mm         4.4%  (AR p75=97.2%, AvP p75=80.2%)
    Talabat Oman – Jalan      10.0%  (AR p75=100.0%, AvP p75=103.1%)
    Talabat UAE – Ajman        7.7%  (AR p75=100.0%, AvP p75=103.2%)
    Talabat UAE – Al ain       2.2%  (AR p75=100.0%, AvP p75=101.0%)
    Glovo (all markets)        5.9%  (AR p75=100.0%, AvP p75=100.8%)

  NOTE: AR p75 = 100% in most markets, meaning the elite
  bar requires near-perfect acceptance. AvP p75 > 100%
  in most non-Philippines markets (elite riders work
  slightly beyond their scheduled hours).
  Ramadan (mid-Mar) visibly depresses UAE numbers.

  Created: 2026-05-11
=======================================================*/

WITH

-- STEP 1A: DAILY ACCEPTANCE RATE per rider-city-day.
-- The deliveries array has one entry per entity (e.g., brand/sub-brand).
-- We unnest and SUM across entities to get the rider's full-day totals.
-- KPI: AR = (accepted - manual_undispatched) / notified
daily_ar AS (
  SELECT
    r.created_date_local,
    r.country_code,
    r.city_id,
    r.rider_id,
    -- city_key: shared pool key for benchmarking (Glovo = one global pool)
    CASE WHEN STARTS_WITH(r.country_code, 'gv-') THEN 'glovo_all'
         ELSE CONCAT(r.country_code, '_', CAST(r.city_id AS STRING))
    END AS city_key,
    -- Human-readable label for output rows
    CASE
      WHEN r.country_code = 'sa' THEN 'Hungerstation – Jazan'
      WHEN r.country_code = 'ec' THEN CONCAT('PedidosYa – ', r.city_name)
      WHEN r.country_code = 'ph' THEN CONCAT('Pandora – ', r.city_name)
      WHEN r.country_code = 'ae' THEN CONCAT('Talabat UAE – ', r.city_name)
      WHEN r.country_code = 'om' THEN 'Talabat Oman – Jalan'
      ELSE 'Glovo (all markets)'
    END AS city_label,
    SUM(d.actual_rider_accepted)  AS accepted,
    SUM(d.manual_undispatched)    AS undispatched,
    SUM(d.actual_rider_notified)  AS notified
  FROM `fulfillment-dwh-production.cl.rider_kpi` r,
    UNNEST(r.deliveries) AS d
  WHERE (
      (r.country_code = 'sa' AND r.city_name = 'Jazan')
    OR (r.country_code = 'ec' AND r.city_name IN ('Guayaquil', 'Quito'))
    OR (r.country_code = 'ph' AND r.city_name IN ('Manila', 'South mm'))
    OR (r.country_code = 'ae' AND r.city_name IN ('Al ain', 'Ajman'))
    OR (r.country_code = 'om' AND r.city_name = 'Jalan')
    OR STARTS_WITH(r.country_code, 'gv-')
  )
  AND r.created_date_local >= DATE_SUB(CURRENT_DATE(), INTERVAL 3 MONTH)
  AND d.actual_rider_notified > 0  -- only days where rider received delivery offers
  GROUP BY 1, 2, 3, 4, 5, 6
),

-- STEP 1B: DAILY PLAN VS. ACTUAL HOURS per rider-city-day.
-- working_time and planned_working_time are RIDER-LEVEL fields (not per entity),
-- so we read the main row WITHOUT unnesting to avoid double-counting.
-- KPI: AvP = actual_working_seconds / planned_working_seconds
daily_avp AS (
  SELECT
    created_date_local,
    country_code,
    city_id,
    rider_id,
    CASE WHEN STARTS_WITH(country_code, 'gv-') THEN 'glovo_all'
         ELSE CONCAT(country_code, '_', CAST(city_id AS STRING))
    END AS city_key,
    planned_working_time,
    working_time
  FROM `fulfillment-dwh-production.cl.rider_kpi`
  WHERE (
      (country_code = 'sa' AND city_name = 'Jazan')
    OR (country_code = 'ec' AND city_name IN ('Guayaquil', 'Quito'))
    OR (country_code = 'ph' AND city_name IN ('Manila', 'South mm'))
    OR (country_code = 'ae' AND city_name IN ('Al ain', 'Ajman'))
    OR (country_code = 'om' AND city_name = 'Jalan')
    OR STARTS_WITH(country_code, 'gv-')
  )
  AND created_date_local >= DATE_SUB(CURRENT_DATE(), INTERVAL 3 MONTH)
  AND planned_working_time > 0  -- rider must have had scheduled shifts that day
),

-- STEP 2: WEEKLY KPI PER RIDER-CITY.
-- Aggregate daily data to calendar weeks (Monday = week start).
-- Correctly compute AR and AvP by summing numerator/denominator first,
-- then dividing — more accurate than averaging daily rates.
-- Only includes riders who had BOTH delivery activity AND scheduled shifts.
weekly_kpi AS (
  SELECT
    DATE_TRUNC(ar.created_date_local, WEEK(MONDAY)) AS week_start,
    ar.city_key,
    ar.city_label,
    ar.rider_id,
    -- Weekly AR: sum across all active days, then divide
    SAFE_DIVIDE(
      SUM(ar.accepted - ar.undispatched),
      NULLIF(SUM(ar.notified), 0)
    ) AS weekly_ar,
    -- Weekly AvP: sum actual and planned seconds across all scheduled days
    SAFE_DIVIDE(
      SUM(avp.working_time),
      NULLIF(SUM(avp.planned_working_time), 0)
    ) AS weekly_avp
  FROM daily_ar ar
  JOIN daily_avp avp
    ON  ar.created_date_local = avp.created_date_local
    AND ar.rider_id            = avp.rider_id
    AND ar.country_code        = avp.country_code
    AND ar.city_id             = avp.city_id
  GROUP BY 1, 2, 3, 4
  HAVING weekly_ar IS NOT NULL AND weekly_avp IS NOT NULL
),

-- STEP 3: FIXED P75 BENCHMARK PER CITY-GROUP.
-- Computed from ALL weekly observations in the 3-month window.
-- Glovo: one global p75 across all gv-* markets combined.
-- Other markets: one p75 per city.
-- *** FREEZE THIS NUMBER AT LAUNCH — DO NOT RECALCULATE AFTER ROLLOUT ***
-- APPROX_QUANTILES(value, 100)[OFFSET(75)] = 75th percentile.
city_benchmarks AS (
  SELECT
    city_key,
    ANY_VALUE(city_label)                                    AS city_label,
    ROUND(APPROX_QUANTILES(weekly_ar,  100)[OFFSET(75)], 4) AS p75_ar,
    ROUND(APPROX_QUANTILES(weekly_avp, 100)[OFFSET(75)], 4) AS p75_avp,
    COUNT(DISTINCT rider_id)                                 AS riders_in_benchmark,
    COUNT(DISTINCT week_start)                               AS weeks_in_benchmark
  FROM weekly_kpi
  GROUP BY 1
),

-- STEP 4: 4-WEEK ROLLING AVERAGE OF AR AND AVP PER RIDER-WEEK.
-- For each rider-week, averages the current week plus up to 3 prior
-- active weeks (weeks where the rider had data in this table).
-- Purpose: smooth out single-week noise (outages, bad weather, holidays).
-- Note: ROWS BETWEEN 3 PRECEDING AND CURRENT ROW = previous 3 active weeks,
-- not necessarily 3 calendar weeks (inactive weeks are simply skipped).
rolling_4w AS (
  SELECT
    week_start,
    city_key,
    city_label,
    rider_id,
    AVG(weekly_ar) OVER (
      PARTITION BY city_key, rider_id
      ORDER BY week_start
      ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
    ) AS rolling_4w_ar,
    AVG(weekly_avp) OVER (
      PARTITION BY city_key, rider_id
      ORDER BY week_start
      ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
    ) AS rolling_4w_avp
  FROM weekly_kpi
),

-- STEP 5: WEEKLY % ABOVE BOTH BENCHMARKS.
-- For each city-week: how many active riders have their 4W rolling averages
-- above BOTH p75 thresholds simultaneously?
-- Also shows per-KPI breakdowns to diagnose which KPI is the bottleneck.
weekly_results AS (
  SELECT
    r.week_start,
    r.city_key,
    b.city_label,
    b.p75_ar,
    b.p75_avp,
    b.riders_in_benchmark,
    COUNT(DISTINCT r.rider_id)                                              AS active_riders,
    COUNTIF(r.rolling_4w_ar >= b.p75_ar AND r.rolling_4w_avp >= b.p75_avp) AS above_both,
    COUNTIF(r.rolling_4w_ar >= b.p75_ar)                                   AS above_ar,
    COUNTIF(r.rolling_4w_avp >= b.p75_avp)                                 AS above_avp
  FROM rolling_4w r
  JOIN city_benchmarks b ON r.city_key = b.city_key
  GROUP BY 1, 2, 3, 4, 5, 6
)

-- FINAL OUTPUT: one row per city per week.
-- pct_above_both = the headline Milestone 1 success metric.
-- The most recent stable week's value = Day-0 baseline before launch.
-- Track this weekly post-launch; a sustained upward trend = initiative is working.
SELECT
  week_start,
  city_label                                                    AS city,
  ROUND(p75_ar  * 100, 1)                                      AS benchmark_ar_p75_pct,
  ROUND(p75_avp * 100, 1)                                      AS benchmark_avp_p75_pct,
  active_riders,
  riders_in_benchmark,
  above_both                                                    AS riders_above_both,
  ROUND(SAFE_DIVIDE(above_both, active_riders) * 100, 1)       AS pct_above_both,
  ROUND(SAFE_DIVIDE(above_ar,   active_riders) * 100, 1)       AS pct_above_ar,
  ROUND(SAFE_DIVIDE(above_avp,  active_riders) * 100, 1)       AS pct_above_avp
FROM weekly_results
ORDER BY city_label, week_start
