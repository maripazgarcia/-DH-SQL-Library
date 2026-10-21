/*====================================================================
  TABLE: logistics-data-storage-staging.Maripaz.m1_above_threshold_weekly
====================================================================
  PURPOSE:
    Weekly tracking of the Milestone 1 headline success metric:
    % of riders whose 4-week rolling average AR and AvP exceeds
    the city-level rolling P75 benchmark.
    One row per city per week.

  GRAIN: country_code + city_id + week_start (Monday)

  REFRESH: Every Monday via BQ Scheduled Query.
           Rebuilds the full 1-year history on each run.

  KEY DESIGN NOTES:
    - de2 excluded everywhere (test country).
    - vertical: standard brand classification by country_code.
    - Quarterly P75 benchmark: computed from the prior calendar quarter's
      rider data. Q uses P75 from Q-1 (e.g. Apr–Jun uses Jan–Mar).
      Source data uses an 18-month lookback so Q-1 is always available;
      final output rows are filtered to the most recent 1 year.
    - 4W rolling avg: current week + up to 3 prior active weeks
      per rider (inactive weeks skipped, not counted as 0).
    - pct_above_both is the headline Milestone 1 success metric.

  VERTICAL CLASSIFICATION (country_code based):
    Pandora      → bd,hk,kh,la,mm,my,ph,pk,sg,tw,at,ca,de,fi,
                   no,se,sk,tr,t3,cz,hu,vn
    Talabat      → ae,bh,eg,iq,jo,kw,om,qa
    Hungerstation → sa
    PedidosYa    → ar,bo,cl,cr,do,ec,gt,hn,ni,py,pe,sv,uy,ve,pa
    Glovo        → all gv-*
    Other        → everything else
    EXCLUDED     → de2 (test country)

  CREATED: 2026-05-18
====================================================================*/

CREATE OR REPLACE TABLE `logistics-data-storage-staging.Maripaz.m1_above_threshold_weekly`
PARTITION BY week_start
CLUSTER BY country_code, city_id
OPTIONS(
  description = "Weekly % of riders above quarterly P75 benchmark on AR and AvP. Rebuilt every Monday. 1-year output window. de2 excluded.",
  labels = [("owner", "maripaz"), ("theme", "loyalty_m1")]
)
AS

WITH

-- ---------------------------------------------------------------
-- STEP 1: Region lookup
-- ---------------------------------------------------------------
country_dim AS (
  SELECT
    country_code,
    region,
    region_short_name
  FROM `fulfillment-dwh-production.cl.countries`
),

-- ---------------------------------------------------------------
-- STEP 2A: Weekly AR per rider per city
-- de2 excluded.
-- ---------------------------------------------------------------
weekly_ar AS (
  SELECT
    DATE_TRUNC(r.created_date_local, WEEK(MONDAY)) AS week_start,
    r.country_code,
    r.city_id,
    r.city_name,
    r.rider_id,
    SAFE_DIVIDE(
      SUM(d.actual_rider_accepted) - SUM(d.manual_undispatched),
      NULLIF(SUM(d.actual_rider_notified), 0)
    ) AS weekly_ar
  FROM `fulfillment-dwh-production.cl.rider_kpi` r,
    UNNEST(r.deliveries) AS d
  WHERE r.created_date_local >= DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 18 MONTH)
    AND r.created_date_local <  DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY))
    AND d.actual_rider_notified > 0
    AND r.country_code != 'de2'
  GROUP BY 1, 2, 3, 4, 5
),

-- ---------------------------------------------------------------
-- STEP 2B: Weekly AvP per rider per city (no unnesting)
-- de2 excluded.
-- ---------------------------------------------------------------
weekly_avp AS (
  SELECT
    DATE_TRUNC(created_date_local, WEEK(MONDAY)) AS week_start,
    country_code,
    city_id,
    rider_id,
    SAFE_DIVIDE(
      SUM(working_time),
      NULLIF(SUM(planned_working_time), 0)
    ) AS weekly_avp
  FROM `fulfillment-dwh-production.cl.rider_kpi`
  WHERE created_date_local >= DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 18 MONTH)
    AND created_date_local <  DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY))
    AND planned_working_time > 0
    AND country_code != 'de2'
  GROUP BY 1, 2, 3, 4
),

-- ---------------------------------------------------------------
-- STEP 3: Join AR and AvP at rider-week level
-- ---------------------------------------------------------------
weekly_kpi AS (
  SELECT
    ar.week_start,
    ar.country_code,
    ar.city_id,
    ar.city_name,
    ar.rider_id,
    ar.weekly_ar,
    avp.weekly_avp
  FROM weekly_ar ar
  JOIN weekly_avp avp
    ON  ar.week_start   = avp.week_start
    AND ar.country_code = avp.country_code
    AND ar.city_id      = avp.city_id
    AND ar.rider_id     = avp.rider_id
  WHERE ar.weekly_ar   IS NOT NULL
    AND avp.weekly_avp IS NOT NULL
),

-- ---------------------------------------------------------------
-- STEP 4: Quarterly P75 benchmark per city
-- Each row = benchmark that applies to the NEXT quarter.
-- Q uses all rider-week data from Q-1 to compute P75.
-- ---------------------------------------------------------------
quarterly_benchmarks AS (
  SELECT
    DATE_ADD(DATE_TRUNC(week_start, QUARTER), INTERVAL 1 QUARTER) AS applies_to_quarter,
    country_code,
    city_id,
    APPROX_QUANTILES(weekly_ar,  100)[OFFSET(75)] AS benchmark_ar_p75,
    APPROX_QUANTILES(weekly_avp, 100)[OFFSET(75)] AS benchmark_avp_p75
  FROM weekly_kpi
  GROUP BY 1, 2, 3
),

-- ---------------------------------------------------------------
-- STEP 5: 4-week rolling average per rider per week
-- ROWS BETWEEN 3 PRECEDING AND CURRENT ROW = current week
-- plus up to 3 prior active weeks. Inactive weeks are skipped.
-- ---------------------------------------------------------------
rolling_4w AS (
  SELECT
    week_start,
    country_code,
    city_id,
    city_name,
    rider_id,
    AVG(weekly_ar) OVER (
      PARTITION BY country_code, city_id, rider_id
      ORDER BY week_start
      ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
    ) AS rolling_4w_ar,
    AVG(weekly_avp) OVER (
      PARTITION BY country_code, city_id, rider_id
      ORDER BY week_start
      ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
    ) AS rolling_4w_avp
  FROM weekly_kpi
),

-- ---------------------------------------------------------------
-- STEP 6: Compare each rider's rolling avg to city benchmark
-- ---------------------------------------------------------------
flagged AS (
  SELECT
    r.week_start,
    r.country_code,
    r.city_id,
    r.city_name,
    r.rider_id,
    b.benchmark_ar_p75,
    b.benchmark_avp_p75,
    r.rolling_4w_ar  >= b.benchmark_ar_p75                                               AS above_ar,
    r.rolling_4w_avp >= b.benchmark_avp_p75                                              AS above_avp,
    (r.rolling_4w_ar >= b.benchmark_ar_p75 AND r.rolling_4w_avp >= b.benchmark_avp_p75) AS above_both
  FROM rolling_4w r
  JOIN quarterly_benchmarks b
    ON  r.country_code                          = b.country_code
    AND r.city_id                               = b.city_id
    AND DATE_TRUNC(r.week_start, QUARTER)       = b.applies_to_quarter
)

-- ---------------------------------------------------------------
-- STEP 7: Aggregate to city-week level
-- ---------------------------------------------------------------
SELECT
  week_start,
  country_code,
  city_id,
  MAX(city_name)            AS city_name,

  -- Standard vertical classification
  CASE
    WHEN country_code IN (
      'bd','hk','kh','la','mm','my','ph','pk','sg','tw',
      'at','ca','de','fi','no','se',
      'sk','tr','t3','cz','hu','vn'
    ) THEN 'Pandora'
    WHEN country_code IN ('ae','bh','eg','iq','jo','kw','om','qa') THEN 'Talabat'
    WHEN country_code = 'sa'                                        THEN 'Hungerstation'
    WHEN country_code IN (
      'ar','bo','cl','cr','do','ec','gt','hn','ni','py','pe','sv','uy','ve','pa'
    ) THEN 'PedidosYa'
    WHEN STARTS_WITH(country_code, 'gv-')                          THEN 'Glovo'
    ELSE 'Other'
  END                       AS vertical,

  -- Canary tag
  CASE
    WHEN country_code = 'sa' AND city_id = 209         THEN 'Hungerstation'
    WHEN country_code = 'ec' AND city_id IN (1, 2)     THEN 'PedidosYa'
    WHEN country_code = 'ph' AND city_id IN (1, 3)     THEN 'Pandora'
    WHEN country_code = 'ae' AND city_id IN (201, 202) THEN 'Talabat UAE'
    WHEN country_code = 'om' AND city_id = 211         THEN 'Talabat Oman'
    -- WHEN STARTS_WITH(country_code, 'gv-') THEN 'Glovo'  -- Glovo canary cities not yet defined
    ELSE NULL
  END                       AS canary_tag,

  MAX(cd.region)            AS region,
  MAX(cd.region_short_name) AS region_short_name,

  -- Benchmark values (recomputed each Monday from last 13 weeks)
  ROUND(MAX(benchmark_ar_p75)  * 100, 2) AS benchmark_ar_p75,
  ROUND(MAX(benchmark_avp_p75) * 100, 2) AS benchmark_avp_p75,

  -- Rider counts
  COUNT(DISTINCT rider_id)   AS active_riders,
  COUNTIF(above_ar)          AS riders_above_ar,
  COUNTIF(above_avp)         AS riders_above_avp,
  COUNTIF(above_both)        AS riders_above_both,

  -- Percentages
  ROUND(SAFE_DIVIDE(COUNTIF(above_ar),   COUNT(DISTINCT rider_id)) * 100, 2) AS pct_above_ar,
  ROUND(SAFE_DIVIDE(COUNTIF(above_avp),  COUNT(DISTINCT rider_id)) * 100, 2) AS pct_above_avp,
  ROUND(SAFE_DIVIDE(COUNTIF(above_both), COUNT(DISTINCT rider_id)) * 100, 2) AS pct_above_both

FROM flagged
LEFT JOIN country_dim cd USING (country_code)
WHERE week_start >= DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 YEAR)
GROUP BY 1, 2, 3, 5, 6  -- 5 = vertical, 6 = canary_tag
