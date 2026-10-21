/*====================================================================
  TABLE: logistics-data-storage-staging.Maripaz.m1_distribution_weekly
====================================================================
  PURPOSE:
    Weekly P25 / P50 / P75 of all 5 KPIs, computed across the
    individual rider distributions within each city.
    One row per city per week. Used for distribution shift charts
    in the Milestone 1 Looker dashboard (Option 1 metric).

  GRAIN: country_code + city_id + week_start (Monday)

  REFRESH: Every Monday via BQ Scheduled Query.
           Rebuilds the full 2-year history on each run.

  KEY DESIGN NOTES:
    - de2 excluded everywhere (test country).
    - vertical: standard brand classification by country_code.
    - Percentiles computed from individual rider weekly values,
      not daily. APPROX_QUANTILES — accurate within ±1%.
    - special_hours only reliable for Talabat UAE and some gv-* markets.

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

CREATE OR REPLACE TABLE `logistics-data-storage-staging.Maripaz.m1_distribution_weekly`
PARTITION BY week_start
CLUSTER BY country_code, city_id
OPTIONS(
  description = "Weekly P25/P50/P75 per city for 5 rider KPIs. Rebuilt every Monday. 2-year window. de2 excluded.",
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
-- STEP 2A: Rider-level weekly aggregates (no unnesting)
-- AvP, tenure, special hours are rider-level fields.
-- de2 excluded.
-- ---------------------------------------------------------------
rider_weekly AS (
  SELECT
    DATE_TRUNC(created_date_local, WEEK(MONDAY)) AS week_start,
    country_code,
    city_id,
    city_name,
    rider_id,
    SAFE_DIVIDE(
      SUM(working_time),
      NULLIF(SUM(planned_working_time), 0)
    )                          AS rider_avp,
    AVG(tenure_in_weeks)       AS rider_tenure,
    SUM(peak_time) / 3600      AS rider_special_hours
  FROM `fulfillment-dwh-production.cl.rider_kpi`
  WHERE created_date_local >= DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 2 YEAR)
    AND created_date_local <  DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY))
    AND planned_working_time > 0
    AND country_code != 'de2'
  GROUP BY 1, 2, 3, 4, 5
),

-- ---------------------------------------------------------------
-- STEP 2B: Entity-level weekly aggregates (unnest deliveries)
-- AR and deliveries require the deliveries array.
-- de2 excluded.
-- ---------------------------------------------------------------
delivery_weekly AS (
  SELECT
    DATE_TRUNC(r.created_date_local, WEEK(MONDAY)) AS week_start,
    r.country_code,
    r.city_id,
    r.rider_id,
    SAFE_DIVIDE(
      SUM(d.actual_rider_accepted) - SUM(d.manual_undispatched),
      NULLIF(SUM(d.actual_rider_notified), 0)
    )                               AS rider_ar,
    SUM(d.completed_deliveries)     AS rider_deliveries
  FROM `fulfillment-dwh-production.cl.rider_kpi` r,
    UNNEST(r.deliveries) AS d
  WHERE r.created_date_local >= DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 2 YEAR)
    AND r.created_date_local <  DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY))
    AND d.actual_rider_notified > 0
    AND r.country_code != 'de2'
  GROUP BY 1, 2, 3, 4
),

-- ---------------------------------------------------------------
-- STEP 3: Join AR + AvP at rider-week level
-- ---------------------------------------------------------------
rider_kpis AS (
  SELECT
    rw.week_start,
    rw.country_code,
    rw.city_id,
    rw.city_name,
    rw.rider_id,
    dw.rider_ar,
    rw.rider_avp,
    dw.rider_deliveries,
    rw.rider_tenure,
    rw.rider_special_hours
  FROM rider_weekly rw
  JOIN delivery_weekly dw
    ON  rw.week_start   = dw.week_start
    AND rw.country_code = dw.country_code
    AND rw.city_id      = dw.city_id
    AND rw.rider_id     = dw.rider_id
  WHERE rw.rider_avp IS NOT NULL
    AND dw.rider_ar  IS NOT NULL
)

-- ---------------------------------------------------------------
-- STEP 4: Aggregate to city-week with P25 / P50 / P75
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

  COUNT(DISTINCT rider_id)  AS active_riders,

  -- Acceptance Rate distribution
  ROUND(APPROX_QUANTILES(rider_ar, 100)[OFFSET(25)] * 100, 2) AS ar_p25,
  ROUND(APPROX_QUANTILES(rider_ar, 100)[OFFSET(50)] * 100, 2) AS ar_p50,
  ROUND(APPROX_QUANTILES(rider_ar, 100)[OFFSET(75)] * 100, 2) AS ar_p75,

  -- Plan vs. Actual Hours distribution
  ROUND(APPROX_QUANTILES(rider_avp, 100)[OFFSET(25)] * 100, 2) AS avp_p25,
  ROUND(APPROX_QUANTILES(rider_avp, 100)[OFFSET(50)] * 100, 2) AS avp_p50,
  ROUND(APPROX_QUANTILES(rider_avp, 100)[OFFSET(75)] * 100, 2) AS avp_p75,

  -- Deliveries per rider per week
  ROUND(APPROX_QUANTILES(rider_deliveries, 100)[OFFSET(25)], 1) AS deliveries_p25,
  ROUND(APPROX_QUANTILES(rider_deliveries, 100)[OFFSET(50)], 1) AS deliveries_p50,
  ROUND(APPROX_QUANTILES(rider_deliveries, 100)[OFFSET(75)], 1) AS deliveries_p75,

  -- Tenure distribution (weeks)
  ROUND(APPROX_QUANTILES(rider_tenure, 100)[OFFSET(25)], 1) AS tenure_p25,
  ROUND(APPROX_QUANTILES(rider_tenure, 100)[OFFSET(50)], 1) AS tenure_p50,
  ROUND(APPROX_QUANTILES(rider_tenure, 100)[OFFSET(75)], 1) AS tenure_p75,

  -- Special Hours per rider (peak demand hours)
  -- NOTE: only reliable for Talabat UAE and some gv-* markets.
  ROUND(APPROX_QUANTILES(rider_special_hours, 100)[OFFSET(25)], 2) AS special_hours_p25,
  ROUND(APPROX_QUANTILES(rider_special_hours, 100)[OFFSET(50)], 2) AS special_hours_p50,
  ROUND(APPROX_QUANTILES(rider_special_hours, 100)[OFFSET(75)], 2) AS special_hours_p75

FROM rider_kpis
LEFT JOIN country_dim cd USING (country_code)
GROUP BY 1, 2, 3, 5, 6  -- 5 = vertical, 6 = canary_tag
ORDER BY country_code, city_id, week_start
