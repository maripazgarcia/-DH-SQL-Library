/*=======================================================
  MILESTONE 1 METRIC: "Above-Threshold Rider Share" — GLOBAL
  =======================================================
  Same logic as m1_above_threshold_rider_share.sql but
  covers ALL countries and ALL cities globally, with a
  canary_tag column to identify Milestone 1 pilot cities.

  Adds P25 and P50 benchmarks alongside P75, so you can
  see the full distribution shape per city and compare
  how tight or spread the KPI distribution is.

  HOW TO READ THE OUTPUT:
    - canary_tag: label for canary cities, NULL otherwise.
      Filter WHERE canary_tag IS NOT NULL to see only
      the canary scope.
    - benchmark_*_p25/p50/p75: the three percentile
      thresholds for each KPI (P75 = the frozen launch
      benchmark; P25/P50 = context only).
    - pct_above_p75_both: the headline Milestone 1 metric.
    - pct_above_p50_both / pct_above_p25_both: context
      metrics — show how the broader mid-tier is moving.
    - The most recent stable week = Day-0 baseline.

  SOURCE TABLE: fulfillment-dwh-production.cl.rider_kpi
  BILLING PROJECT: dhub-data-commune

  CANARY CITIES (tagged in canary_tag):
    SA   Jazan             → 'Hungerstation – Canary'
    EC   Guayaquil, Quito  → 'PedidosYa – Canary'
    PH   Manila, South mm  → 'Pandora – Canary'
    AE   Al ain, Ajman     → 'Talabat UAE – Canary'
    OM   Jalan             → 'Talabat Oman – Canary'
    gv-* All Glovo cities  → 'Glovo – Canary (all markets)'

  Created: 2026-05-11
=======================================================*/

WITH

-- STEP 1A: DAILY ACCEPTANCE RATE per rider-city-day.
-- Covers ALL countries and cities globally (no city filter).
-- The deliveries array has one entry per entity — we unnest
-- and SUM across entities to get the rider's full-day totals.
-- KPI: AR = (accepted - manual_undispatched) / notified
daily_ar AS (
  SELECT
    r.created_date_local,
    r.country_code,
    r.city_id,
    r.city_name,
    r.rider_id,
    -- Unique city key: one benchmark per city (no cross-country pooling)
    CONCAT(r.country_code, '_', CAST(r.city_id AS STRING)) AS city_key,
    -- Canary tag: identifies pilot cities for Milestone 1.
    -- NULL = not a canary city. Filter on this column to scope results.
    CASE
      WHEN r.country_code = 'sa' AND r.city_name = 'Jazan'
        THEN 'Hungerstation – Canary'
      WHEN r.country_code = 'ec' AND r.city_name IN ('Guayaquil', 'Quito')
        THEN 'PedidosYa – Canary'
      WHEN r.country_code = 'ph' AND r.city_name IN ('Manila', 'South mm')
        THEN 'Pandora – Canary'
      WHEN r.country_code = 'ae' AND r.city_name IN ('Al ain', 'Ajman')
        THEN 'Talabat UAE – Canary'
      WHEN r.country_code = 'om' AND r.city_name = 'Jalan'
        THEN 'Talabat Oman – Canary'
      WHEN STARTS_WITH(r.country_code, 'gv-')
        THEN 'Glovo – Canary (all markets)'
      ELSE NULL
    END AS canary_tag,
    SUM(d.actual_rider_accepted)  AS accepted,
    SUM(d.manual_undispatched)    AS undispatched,
    SUM(d.actual_rider_notified)  AS notified
  FROM `fulfillment-dwh-production.cl.rider_kpi` r,
    UNNEST(r.deliveries) AS d
  WHERE r.created_date_local >= DATE_SUB(CURRENT_DATE(), INTERVAL 3 MONTH)
    AND d.actual_rider_notified > 0  -- only days where rider received delivery offers
  GROUP BY 1, 2, 3, 4, 5, 6, 7
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
    CONCAT(country_code, '_', CAST(city_id AS STRING)) AS city_key,
    planned_working_time,
    working_time
  FROM `fulfillment-dwh-production.cl.rider_kpi`
  WHERE created_date_local >= DATE_SUB(CURRENT_DATE(), INTERVAL 3 MONTH)
    AND planned_working_time > 0  -- rider must have had scheduled shifts that day
),

-- STEP 2: WEEKLY KPI PER RIDER-CITY.
-- Aggregate daily data to calendar weeks (Monday = week start).
-- Sum numerator/denominator first, then divide — more accurate than
-- averaging daily rates.
-- Only includes riders with BOTH delivery activity AND scheduled shifts.
weekly_kpi AS (
  SELECT
    DATE_TRUNC(ar.created_date_local, WEEK(MONDAY)) AS week_start,
    ar.city_key,
    ar.country_code,
    ar.city_name,
    ar.canary_tag,
    ar.rider_id,
    -- Weekly AR: sum accepted and notified across all active days, then divide
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
  GROUP BY 1, 2, 3, 4, 5, 6
  HAVING weekly_ar IS NOT NULL AND weekly_avp IS NOT NULL
),

-- STEP 3: P25, P50, AND P75 BENCHMARKS PER CITY.
-- Computed from ALL weekly observations in the 3-month window.
-- P75 = the frozen launch benchmark for the headline metric.
-- P50 and P25 = additional context to understand the distribution shape.
-- *** FREEZE P75 AT LAUNCH — DO NOT RECALCULATE AFTER ROLLOUT ***
city_benchmarks AS (
  SELECT
    city_key,
    ANY_VALUE(country_code) AS country_code,
    ANY_VALUE(city_name)    AS city_name,
    ANY_VALUE(canary_tag)   AS canary_tag,
    -- Acceptance Rate percentiles
    ROUND(APPROX_QUANTILES(weekly_ar, 100)[OFFSET(25)], 4) AS p25_ar,
    ROUND(APPROX_QUANTILES(weekly_ar, 100)[OFFSET(50)], 4) AS p50_ar,
    ROUND(APPROX_QUANTILES(weekly_ar, 100)[OFFSET(75)], 4) AS p75_ar,
    -- Plan vs. Actual Hours percentiles
    ROUND(APPROX_QUANTILES(weekly_avp, 100)[OFFSET(25)], 4) AS p25_avp,
    ROUND(APPROX_QUANTILES(weekly_avp, 100)[OFFSET(50)], 4) AS p50_avp,
    ROUND(APPROX_QUANTILES(weekly_avp, 100)[OFFSET(75)], 4) AS p75_avp,
    COUNT(DISTINCT rider_id)   AS riders_in_benchmark,
    COUNT(DISTINCT week_start) AS weeks_in_benchmark
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

-- STEP 5: WEEKLY % ABOVE EACH PERCENTILE THRESHOLD.
-- For each city-week: counts active riders whose 4W rolling averages
-- exceed P25, P50, or P75 on both KPIs simultaneously.
--   pct_above_p75_both = headline Milestone 1 metric (top 25% bar)
--   pct_above_p50_both = mid-tier health check (above median)
--   pct_above_p25_both = broad engagement check (above bottom quartile)
weekly_results AS (
  SELECT
    r.week_start,
    b.country_code,
    b.city_name,
    b.canary_tag,
    b.p25_ar,
    b.p50_ar,
    b.p75_ar,
    b.p25_avp,
    b.p50_avp,
    b.p75_avp,
    b.riders_in_benchmark,
    COUNT(DISTINCT r.rider_id) AS active_riders,

    -- P75 counts: headline metric — requires elite performance on both KPIs
    COUNTIF(r.rolling_4w_ar >= b.p75_ar AND r.rolling_4w_avp >= b.p75_avp) AS above_p75_both,
    COUNTIF(r.rolling_4w_ar >= b.p75_ar)                                    AS above_p75_ar,
    COUNTIF(r.rolling_4w_avp >= b.p75_avp)                                  AS above_p75_avp,

    -- P50 counts: above-median performance on both KPIs
    COUNTIF(r.rolling_4w_ar >= b.p50_ar AND r.rolling_4w_avp >= b.p50_avp) AS above_p50_both,
    COUNTIF(r.rolling_4w_ar >= b.p50_ar)                                    AS above_p50_ar,
    COUNTIF(r.rolling_4w_avp >= b.p50_avp)                                  AS above_p50_avp,

    -- P25 counts: above bottom-quartile on both KPIs
    COUNTIF(r.rolling_4w_ar >= b.p25_ar AND r.rolling_4w_avp >= b.p25_avp) AS above_p25_both,
    COUNTIF(r.rolling_4w_ar >= b.p25_ar)                                    AS above_p25_ar,
    COUNTIF(r.rolling_4w_avp >= b.p25_avp)                                  AS above_p25_avp
  FROM rolling_4w r
  JOIN city_benchmarks b ON r.city_key = b.city_key
  GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11
)

-- FINAL OUTPUT: one row per city per week, all countries globally.
-- To filter canary cities only: add WHERE canary_tag IS NOT NULL
-- To see a specific vertical: WHERE canary_tag LIKE 'PedidosYa%'
SELECT
  week_start,
  country_code,
  city_name,
  canary_tag,

  -- Fixed benchmarks (P75 = frozen at launch; P50/P25 = context)
  ROUND(p25_ar  * 100, 1)  AS benchmark_ar_p25_pct,
  ROUND(p50_ar  * 100, 1)  AS benchmark_ar_p50_pct,
  ROUND(p75_ar  * 100, 1)  AS benchmark_ar_p75_pct,
  ROUND(p25_avp * 100, 1)  AS benchmark_avp_p25_pct,
  ROUND(p50_avp * 100, 1)  AS benchmark_avp_p50_pct,
  ROUND(p75_avp * 100, 1)  AS benchmark_avp_p75_pct,

  active_riders,
  riders_in_benchmark,

  -- P75 metrics: headline Milestone 1 metric
  above_p75_both                                                   AS riders_above_p75_both,
  ROUND(SAFE_DIVIDE(above_p75_both, active_riders) * 100, 1)      AS pct_above_p75_both,
  ROUND(SAFE_DIVIDE(above_p75_ar,   active_riders) * 100, 1)      AS pct_above_p75_ar,
  ROUND(SAFE_DIVIDE(above_p75_avp,  active_riders) * 100, 1)      AS pct_above_p75_avp,

  -- P50 metrics: above-median riders
  above_p50_both                                                   AS riders_above_p50_both,
  ROUND(SAFE_DIVIDE(above_p50_both, active_riders) * 100, 1)      AS pct_above_p50_both,
  ROUND(SAFE_DIVIDE(above_p50_ar,   active_riders) * 100, 1)      AS pct_above_p50_ar,
  ROUND(SAFE_DIVIDE(above_p50_avp,  active_riders) * 100, 1)      AS pct_above_p50_avp,

  -- P25 metrics: riders above the bottom quartile
  above_p25_both                                                   AS riders_above_p25_both,
  ROUND(SAFE_DIVIDE(above_p25_both, active_riders) * 100, 1)      AS pct_above_p25_both,
  ROUND(SAFE_DIVIDE(above_p25_ar,   active_riders) * 100, 1)      AS pct_above_p25_ar,
  ROUND(SAFE_DIVIDE(above_p25_avp,  active_riders) * 100, 1)      AS pct_above_p25_avp

FROM weekly_results
ORDER BY
  -- Canary cities first, then all others alphabetically
  CASE WHEN canary_tag IS NOT NULL THEN 0 ELSE 1 END,
  country_code,
  city_name,
  week_start
