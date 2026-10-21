/*====================================================================
  TABLE: logistics-data-storage-staging.Maripaz.m1_retention_weekly
====================================================================
  PURPOSE:
    Weekly cohort retention: for each city-week, what % of riders
    who completed a delivery are still delivering 4, 8, and 12 weeks
    later. One row per country_code + city_id + cohort_week.

  GRAIN: country_code + city_id + cohort_week (Monday)

  REFRESH: Every Monday via BQ Scheduled Query.
           Rebuilds the full 2-year cohort history on each run.

  ACTIVE DEFINITION:
    A rider is "active" in a week if they completed ≥1 delivery
    in that week. This uses the completed_deliveries field inside
    the deliveries array of rider_kpi.

  HOW TO READ THE OUTPUT:
    retention_4w_pct  = % of cohort_week riders still active at W+4
    retention_8w_pct  = % of cohort_week riders still active at W+8
    retention_12w_pct = % of cohort_week riders still active at W+12
    NULL = the measurement week (W+4/8/12) is in the future —
           not zero retention, simply not yet measurable.

  WHY NULLS APPEAR:
    Recent cohorts will have NULL for forward windows that haven't
    occurred yet. This is correct and expected. Looker should display
    these as "N/A" or blank, NOT as 0%.

  APPLIES SAME STANDARDS AS OTHER M1 TABLES:
    - de2 excluded (test country)
    - vertical classification by country_code (Pandora/Talabat/etc.)
    - region from cl.countries
    - canary_tag by city_id
    - 2-year cohort window (requires 2yr + 12W of activity data)

  VERTICAL CLASSIFICATION:
    Pandora      → bd,hk,kh,la,mm,my,ph,pk,sg,tw,at,ca,de,fi,
                   no,se,sk,tr,t3,cz,hu,vn
    Talabat      → ae,bh,eg,iq,jo,kw,om,qa
    Hungerstation → sa
    PedidosYa    → ar,bo,cl,cr,do,ec,gt,hn,ni,py,pe,sv,uy,ve,pa
    Glovo        → all gv-*
    Other        → everything else
    EXCLUDED     → de2

  CREATED: 2026-05-22
====================================================================*/

CREATE OR REPLACE TABLE `logistics-data-storage-staging.Maripaz.m1_retention_weekly`
PARTITION BY cohort_week
CLUSTER BY country_code, city_id
OPTIONS(
  description = "Weekly cohort retention (4W/8W/12W) per city. Rebuilt every Monday. 2-year window. de2 excluded.",
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
-- STEP 2: Weekly active riders (completed ≥1 delivery)
-- Pulls 2 years + 12 weeks to cover the forward-look for W+12.
-- de2 excluded.
-- One row per rider per city per week they were active.
-- ---------------------------------------------------------------
weekly_active AS (
  SELECT DISTINCT
    DATE_TRUNC(r.created_date_local, WEEK(MONDAY)) AS week_start,
    r.country_code,
    r.city_id,
    r.city_name,
    r.rider_id
  FROM `fulfillment-dwh-production.cl.rider_kpi` r,
    UNNEST(r.deliveries) AS d
  WHERE d.completed_deliveries > 0
    AND r.country_code != 'de2'
    -- Extra 12 weeks beyond the 2-year cohort window to cover W+12
    AND r.created_date_local >= DATE_SUB(
          DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 2 YEAR)
    AND r.created_date_local <  DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY))
)

-- ---------------------------------------------------------------
-- STEP 3: Join cohorts to their W+4, W+8, W+12 activity weeks
-- Base = riders active in cohort_week (wa0)
-- Forward = riders active 4/8/12 weeks later (wa4, wa8, wa12)
-- NULL retained counts mean the forward week hasn't occurred yet.
-- ---------------------------------------------------------------
SELECT
  wa0.week_start                                                        AS cohort_week,
  wa0.country_code,
  wa0.city_id,
  MAX(wa0.city_name)                                                    AS city_name,

  -- Standard vertical classification
  CASE
    WHEN wa0.country_code IN (
      'bd','hk','kh','la','mm','my','ph','pk','sg','tw',
      'at','ca','de','fi','no','se',
      'sk','tr','t3','cz','hu','vn'
    ) THEN 'Pandora'
    WHEN wa0.country_code IN ('ae','bh','eg','iq','jo','kw','om','qa') THEN 'Talabat'
    WHEN wa0.country_code = 'sa'                                        THEN 'Hungerstation'
    WHEN wa0.country_code IN (
      'ar','bo','cl','cr','do','ec','gt','hn','ni','py','pe','sv','uy','ve','pa'
    ) THEN 'PedidosYa'
    WHEN STARTS_WITH(wa0.country_code, 'gv-')                          THEN 'Glovo'
    ELSE 'Other'
  END                                                                   AS vertical,

  -- Canary tag
  CASE
    WHEN wa0.country_code = 'sa' AND wa0.city_id = 209         THEN 'Hungerstation'
    WHEN wa0.country_code = 'ec' AND wa0.city_id IN (1, 2)     THEN 'PedidosYa'
    WHEN wa0.country_code = 'ph' AND wa0.city_id IN (1, 3)     THEN 'Pandora'
    WHEN wa0.country_code = 'ae' AND wa0.city_id IN (201, 202) THEN 'Talabat UAE'
    WHEN wa0.country_code = 'om' AND wa0.city_id = 211         THEN 'Talabat Oman'
    -- WHEN STARTS_WITH(wa0.country_code, 'gv-') THEN 'Glovo'  -- not yet defined
    ELSE NULL
  END                                                                   AS canary_tag,

  MAX(cd.region)                                                        AS region,
  MAX(cd.region_short_name)                                             AS region_short_name,

  -- Cohort size
  COUNT(DISTINCT wa0.rider_id)                                          AS cohort_size,

  -- 4W retention
  COUNT(DISTINCT wa4.rider_id)                                          AS retained_4w,
  -- NULL if W+4 week is in the future (no data). 0 would be misleading.
  CASE
    WHEN DATE_ADD(wa0.week_start, INTERVAL 4 WEEK) >= DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY))
    THEN NULL
    ELSE ROUND(SAFE_DIVIDE(COUNT(DISTINCT wa4.rider_id),
                           COUNT(DISTINCT wa0.rider_id)) * 100, 1)
  END                                                                   AS retention_4w_pct,

  -- 8W retention
  COUNT(DISTINCT wa8.rider_id)                                          AS retained_8w,
  CASE
    WHEN DATE_ADD(wa0.week_start, INTERVAL 8 WEEK) >= DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY))
    THEN NULL
    ELSE ROUND(SAFE_DIVIDE(COUNT(DISTINCT wa8.rider_id),
                           COUNT(DISTINCT wa0.rider_id)) * 100, 1)
  END                                                                   AS retention_8w_pct,

  -- 12W retention
  COUNT(DISTINCT wa12.rider_id)                                         AS retained_12w,
  CASE
    WHEN DATE_ADD(wa0.week_start, INTERVAL 12 WEEK) >= DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY))
    THEN NULL
    ELSE ROUND(SAFE_DIVIDE(COUNT(DISTINCT wa12.rider_id),
                           COUNT(DISTINCT wa0.rider_id)) * 100, 1)
  END                                                                   AS retention_12w_pct

FROM weekly_active wa0

-- W+4: same rider, same city, 4 weeks later
LEFT JOIN weekly_active wa4
  ON  wa4.rider_id     = wa0.rider_id
  AND wa4.country_code = wa0.country_code
  AND wa4.city_id      = wa0.city_id
  AND wa4.week_start   = DATE_ADD(wa0.week_start, INTERVAL 4 WEEK)

-- W+8
LEFT JOIN weekly_active wa8
  ON  wa8.rider_id     = wa0.rider_id
  AND wa8.country_code = wa0.country_code
  AND wa8.city_id      = wa0.city_id
  AND wa8.week_start   = DATE_ADD(wa0.week_start, INTERVAL 8 WEEK)

-- W+12
LEFT JOIN weekly_active wa12
  ON  wa12.rider_id     = wa0.rider_id
  AND wa12.country_code = wa0.country_code
  AND wa12.city_id      = wa0.city_id
  AND wa12.week_start   = DATE_ADD(wa0.week_start, INTERVAL 12 WEEK)

LEFT JOIN country_dim cd
  ON  wa0.country_code = cd.country_code

-- Only produce rows for cohort weeks within the 2-year window
WHERE wa0.week_start >= DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 2 YEAR)

GROUP BY 1, 2, 3, 5, 6
ORDER BY wa0.country_code, wa0.city_id, wa0.week_start
