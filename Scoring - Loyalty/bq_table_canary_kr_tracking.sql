/*====================================================================
  QUERY: M1 Canary KR Tracking — Direct SELECT for Google Sheets
====================================================================
  PURPOSE:
    Weekly KR tracking for the Loyalty Tier Merging canary rollout.
    Compares the headline M1 metric for canary cities vs their
    look-alike cities over a 3-month Before/After window per rollout.

    Includes both P75 (top performer) and P50 (median rider) benchmarks
    so you can assess whether the impact is broad-based or concentrated.

  HOW TO USE IN GSHEETS:
    Data > Data Connectors > BigQuery > paste this query.
    Filter by city_type (Canary / Look-alike / Global – Canary / Global – Look-alike),
    period (Before / After), or paired_canary to slice the data.

  CANARY CITIES & ROLLOUT DATES:
    PH  Bulacan (220)          2026-08-10
    PH  Batangas (204)         2026-08-10
    OM  Jalan (211)            2026-07-20
    AE  Al Ain (202)           2026-07-27
    AE  Ajman (201)            2026-07-27
    SA  Jazan (209)            2026-07-27
    gv-ug  Kampala (1)         2026-08-10
    EC  Machala (3)            2026-08-17
    EC  Ibarra (8)             2026-08-17

  LOOK-ALIKE CITIES:
    PH  Pampanga (203)         paired with Bulacan
    PH  Bacolod (206)          paired with Batangas
    OM  Sur (203)              paired with Jalan
    AE  Sharjah (200)          paired with Al Ain
    AE  RAK (203)              paired with Ajman
    SA  Hafar al Batin (207)   paired with Jazan
    gv-ci  Abidjan Nord (5)    paired with Kampala (cross-country)
    EC  Manta (7)              paired with Machala
    EC  Portoviejo (9)         paired with Ibarra

  KEY COLUMNS:
    pct_above_both_p75  — % riders above P75 benchmark on AR and AvP (headline KR metric)
    pct_above_both_p50  — % riders above P50 benchmark on AR and AvP (median rider impact)
    period              — 'Before' | 'After'
    city_type           — 'Canary' | 'Look-alike' | 'Global – Canary' | 'Global – Look-alike'
    paired_canary       — which canary city this row belongs to

  CREATED: 2026-06-30
====================================================================*/

WITH

-- ---------------------------------------------------------------
-- Canary + look-alike city manifest
-- ---------------------------------------------------------------
manifest AS (
  SELECT 'ph'    AS country_code, 220 AS city_id, 'Canary'    AS city_type, DATE '2026-08-10' AS rollout_date, 'Bulacan'  AS paired_canary UNION ALL
  SELECT 'ph',    203,            'Look-alike',                DATE '2026-08-10',               'Bulacan'   UNION ALL
  SELECT 'ph',    204,            'Canary',                    DATE '2026-08-10',               'Batangas'  UNION ALL
  SELECT 'ph',    206,            'Look-alike',                DATE '2026-08-10',               'Batangas'  UNION ALL
  SELECT 'om',    211,            'Canary',                    DATE '2026-07-20',               'Jalan'     UNION ALL
  SELECT 'om',    203,            'Look-alike',                DATE '2026-07-20',               'Jalan'     UNION ALL
  SELECT 'ae',    202,            'Canary',                    DATE '2026-07-27',               'Al Ain'    UNION ALL
  SELECT 'ae',    200,            'Look-alike',                DATE '2026-07-27',               'Al Ain'    UNION ALL
  SELECT 'ae',    201,            'Canary',                    DATE '2026-07-27',               'Ajman'     UNION ALL
  SELECT 'ae',    203,            'Look-alike',                DATE '2026-07-27',               'Ajman'     UNION ALL
  SELECT 'sa',    209,            'Canary',                    DATE '2026-07-27',               'Jazan'     UNION ALL
  SELECT 'sa',    207,            'Look-alike',                DATE '2026-07-27',               'Jazan'     UNION ALL
  SELECT 'gv-ug', 1,             'Canary',                    DATE '2026-08-10',               'Kampala'   UNION ALL
  SELECT 'gv-ci', 5,             'Look-alike',                DATE '2026-08-10',               'Kampala'   UNION ALL
  SELECT 'ec',    3,             'Canary',                    DATE '2026-08-17',               'Machala'   UNION ALL
  SELECT 'ec',    7,             'Look-alike',                DATE '2026-08-17',               'Machala'   UNION ALL
  SELECT 'ec',    8,             'Canary',                    DATE '2026-08-17',               'Ibarra'    UNION ALL
  SELECT 'ec',    9,             'Look-alike',                DATE '2026-08-17',               'Ibarra'
),

city_filter AS (
  SELECT DISTINCT country_code, city_id FROM manifest
),

-- ---------------------------------------------------------------
-- STEP 1: Region lookup
-- ---------------------------------------------------------------
country_dim AS (
  SELECT country_code, region, region_short_name
  FROM `fulfillment-dwh-production.cl.countries`
),

-- ---------------------------------------------------------------
-- STEP 2A: Weekly AR per rider — scoped to canary cities only
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
  INNER JOIN city_filter cf
    ON r.country_code = cf.country_code AND r.city_id = cf.city_id
  WHERE r.created_date_local >= DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 18 MONTH)
    AND r.created_date_local <  DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY))
    AND d.actual_rider_notified > 0
    AND r.country_code != 'de2'
  GROUP BY 1, 2, 3, 4, 5
),

-- ---------------------------------------------------------------
-- STEP 2B: Weekly AvP per rider — scoped to canary cities only
-- ---------------------------------------------------------------
weekly_avp AS (
  SELECT
    DATE_TRUNC(r.created_date_local, WEEK(MONDAY)) AS week_start,
    r.country_code,
    r.city_id,
    r.rider_id,
    SAFE_DIVIDE(
      SUM(r.working_time),
      NULLIF(SUM(r.planned_working_time), 0)
    ) AS weekly_avp
  FROM `fulfillment-dwh-production.cl.rider_kpi` r
  INNER JOIN city_filter cf
    ON r.country_code = cf.country_code AND r.city_id = cf.city_id
  WHERE r.created_date_local >= DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 18 MONTH)
    AND r.created_date_local <  DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY))
    AND r.planned_working_time > 0
    AND r.country_code != 'de2'
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
-- STEP 4: Quarterly benchmarks — P75 (headline) + P50 (median)
-- Each row = benchmark applying to the NEXT quarter.
-- ---------------------------------------------------------------
quarterly_benchmarks AS (
  SELECT
    DATE_ADD(DATE_TRUNC(week_start, QUARTER), INTERVAL 1 QUARTER) AS applies_to_quarter,
    country_code,
    city_id,
    APPROX_QUANTILES(weekly_ar,  100)[OFFSET(75)] AS benchmark_ar_p75,
    APPROX_QUANTILES(weekly_avp, 100)[OFFSET(75)] AS benchmark_avp_p75,
    APPROX_QUANTILES(weekly_ar,  100)[OFFSET(50)] AS benchmark_ar_p50,
    APPROX_QUANTILES(weekly_avp, 100)[OFFSET(50)] AS benchmark_avp_p50
  FROM weekly_kpi
  GROUP BY 1, 2, 3
),

-- ---------------------------------------------------------------
-- STEP 5: 4-week rolling average per rider
-- Inactive weeks skipped (not counted as 0).
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
-- STEP 6: Flag each rider above P75 and P50 thresholds
-- ---------------------------------------------------------------
flagged AS (
  SELECT
    r.week_start,
    r.country_code,
    r.city_id,
    r.city_name,
    r.rider_id,
    -- P75
    b.benchmark_ar_p75,
    b.benchmark_avp_p75,
    r.rolling_4w_ar  >= b.benchmark_ar_p75                                                AS above_ar_p75,
    r.rolling_4w_avp >= b.benchmark_avp_p75                                               AS above_avp_p75,
    (r.rolling_4w_ar >= b.benchmark_ar_p75 AND r.rolling_4w_avp >= b.benchmark_avp_p75)  AS above_both_p75,
    -- P50
    b.benchmark_ar_p50,
    b.benchmark_avp_p50,
    r.rolling_4w_ar  >= b.benchmark_ar_p50                                                AS above_ar_p50,
    r.rolling_4w_avp >= b.benchmark_avp_p50                                               AS above_avp_p50,
    (r.rolling_4w_ar >= b.benchmark_ar_p50 AND r.rolling_4w_avp >= b.benchmark_avp_p50)  AS above_both_p50
  FROM rolling_4w r
  JOIN quarterly_benchmarks b
    ON  r.country_code                    = b.country_code
    AND r.city_id                         = b.city_id
    AND DATE_TRUNC(r.week_start, QUARTER) = b.applies_to_quarter
),

-- ---------------------------------------------------------------
-- STEP 7: Aggregate to city-week + join canary metadata
-- ---------------------------------------------------------------
city_weeks AS (
  SELECT
    f.week_start,
    f.country_code,
    f.city_id,
    MAX(f.city_name) AS city_name,

    CASE
      WHEN f.country_code IN (
        'bd','hk','kh','la','mm','my','ph','pk','sg','tw',
        'at','ca','de','fi','no','se','sk','tr','t3','cz','hu','vn'
      ) THEN 'Pandora'
      WHEN f.country_code IN ('ae','bh','eg','iq','jo','kw','om','qa') THEN 'Talabat'
      WHEN f.country_code = 'sa'                                        THEN 'Hungerstation'
      WHEN f.country_code IN (
        'ar','bo','cl','cr','do','ec','gt','hn','ni','py','pe','sv','uy','ve','pa'
      ) THEN 'PedidosYa'
      WHEN STARTS_WITH(f.country_code, 'gv-')                          THEN 'Glovo'
      ELSE 'Other'
    END AS vertical,

    man.city_type,
    man.paired_canary,
    man.rollout_date,

    CASE
      WHEN f.week_start >= DATE_SUB(man.rollout_date, INTERVAL 3 MONTH)
       AND f.week_start <  man.rollout_date
      THEN 'Before'
      WHEN f.week_start >= man.rollout_date
       AND f.week_start <  DATE_ADD(man.rollout_date, INTERVAL 3 MONTH)
      THEN 'After'
      ELSE NULL
    END AS period,

    MAX(cd.region)            AS region,
    MAX(cd.region_short_name) AS region_short_name,

    -- Benchmarks (as %)
    ROUND(MAX(f.benchmark_ar_p75)  * 100, 2) AS benchmark_ar_p75,
    ROUND(MAX(f.benchmark_avp_p75) * 100, 2) AS benchmark_avp_p75,
    ROUND(MAX(f.benchmark_ar_p50)  * 100, 2) AS benchmark_ar_p50,
    ROUND(MAX(f.benchmark_avp_p50) * 100, 2) AS benchmark_avp_p50,

    -- Rider counts
    COUNT(DISTINCT f.rider_id) AS active_riders,

    -- P75 counts and percentages
    COUNTIF(f.above_ar_p75)   AS riders_above_ar_p75,
    COUNTIF(f.above_avp_p75)  AS riders_above_avp_p75,
    COUNTIF(f.above_both_p75) AS riders_above_both_p75,
    ROUND(SAFE_DIVIDE(COUNTIF(f.above_ar_p75),   COUNT(DISTINCT f.rider_id)) * 100, 2) AS pct_above_ar_p75,
    ROUND(SAFE_DIVIDE(COUNTIF(f.above_avp_p75),  COUNT(DISTINCT f.rider_id)) * 100, 2) AS pct_above_avp_p75,
    ROUND(SAFE_DIVIDE(COUNTIF(f.above_both_p75), COUNT(DISTINCT f.rider_id)) * 100, 2) AS pct_above_both_p75,

    -- P50 counts and percentages
    COUNTIF(f.above_ar_p50)   AS riders_above_ar_p50,
    COUNTIF(f.above_avp_p50)  AS riders_above_avp_p50,
    COUNTIF(f.above_both_p50) AS riders_above_both_p50,
    ROUND(SAFE_DIVIDE(COUNTIF(f.above_ar_p50),   COUNT(DISTINCT f.rider_id)) * 100, 2) AS pct_above_ar_p50,
    ROUND(SAFE_DIVIDE(COUNTIF(f.above_avp_p50),  COUNT(DISTINCT f.rider_id)) * 100, 2) AS pct_above_avp_p50,
    ROUND(SAFE_DIVIDE(COUNTIF(f.above_both_p50), COUNT(DISTINCT f.rider_id)) * 100, 2) AS pct_above_both_p50

  FROM flagged f
  JOIN manifest man
    ON  f.country_code = man.country_code
    AND f.city_id      = man.city_id
  LEFT JOIN country_dim cd ON cd.country_code = f.country_code
  GROUP BY
    f.week_start,
    f.country_code,
    f.city_id,
    vertical,
    man.city_type,
    man.paired_canary,
    man.rollout_date,
    period
),

-- ---------------------------------------------------------------
-- City-level: filter to the 3-month window only
-- ---------------------------------------------------------------
city_level AS (
  SELECT * FROM city_weeks WHERE period IS NOT NULL
),

-- ---------------------------------------------------------------
-- Global: canary and look-alike totals separately per (week, period)
-- Recalculates pct from summed counts to avoid averaging averages.
-- ---------------------------------------------------------------
global_level AS (
  SELECT
    week_start,
    'GLOBAL'                        AS country_code,
    0                               AS city_id,
    'All Cities'                    AS city_name,
    'All'                           AS vertical,
    CONCAT('Global – ', city_type)  AS city_type,
    'ALL'                           AS paired_canary,
    CAST(NULL AS DATE)              AS rollout_date,
    period,
    CAST(NULL AS STRING)            AS region,
    CAST(NULL AS STRING)            AS region_short_name,
    CAST(NULL AS FLOAT64)           AS benchmark_ar_p75,
    CAST(NULL AS FLOAT64)           AS benchmark_avp_p75,
    CAST(NULL AS FLOAT64)           AS benchmark_ar_p50,
    CAST(NULL AS FLOAT64)           AS benchmark_avp_p50,
    SUM(active_riders)              AS active_riders,
    SUM(riders_above_ar_p75)        AS riders_above_ar_p75,
    SUM(riders_above_avp_p75)       AS riders_above_avp_p75,
    SUM(riders_above_both_p75)      AS riders_above_both_p75,
    ROUND(SAFE_DIVIDE(SUM(riders_above_ar_p75),   SUM(active_riders)) * 100, 2) AS pct_above_ar_p75,
    ROUND(SAFE_DIVIDE(SUM(riders_above_avp_p75),  SUM(active_riders)) * 100, 2) AS pct_above_avp_p75,
    ROUND(SAFE_DIVIDE(SUM(riders_above_both_p75), SUM(active_riders)) * 100, 2) AS pct_above_both_p75,
    SUM(riders_above_ar_p50)        AS riders_above_ar_p50,
    SUM(riders_above_avp_p50)       AS riders_above_avp_p50,
    SUM(riders_above_both_p50)      AS riders_above_both_p50,
    ROUND(SAFE_DIVIDE(SUM(riders_above_ar_p50),   SUM(active_riders)) * 100, 2) AS pct_above_ar_p50,
    ROUND(SAFE_DIVIDE(SUM(riders_above_avp_p50),  SUM(active_riders)) * 100, 2) AS pct_above_avp_p50,
    ROUND(SAFE_DIVIDE(SUM(riders_above_both_p50), SUM(active_riders)) * 100, 2) AS pct_above_both_p50
  FROM city_level
  GROUP BY week_start, city_type, period
)

-- ---------------------------------------------------------------
-- Final output: city rows + global summary rows
-- ---------------------------------------------------------------
SELECT * FROM city_level
UNION ALL
SELECT * FROM global_level
ORDER BY week_start, country_code, city_id
