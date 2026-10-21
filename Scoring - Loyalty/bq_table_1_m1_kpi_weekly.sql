/*====================================================================
  TABLE: logistics-data-storage-staging.Maripaz.m1_kpi_weekly
====================================================================
  PURPOSE:
    Weekly operational KPI summary per city, all countries globally.
    One row per city per week. Used as the base table for the
    Milestone 1 Looker dashboard WoW / MoM tracking tiles.

  GRAIN: country_code + city_id + week_start (Monday)

  REFRESH: Every Monday via BQ Scheduled Query.
           Rebuilds the full 2-year history on each run.

  KEY DESIGN NOTES:
    - de2 is excluded everywhere (test country).
    - KPIs are computed at daily grain internally (rider × day),
      then DATE_TRUNC'd to week only at the final aggregation step.
    - WoW delta = current week vs the week starting 7 days prior.
    - MoM delta = current week vs the week starting 30 days prior
      (self-join on DATE_SUB 30 days, not LAG 4 weeks).
    - active_riders_90d: riders with ≥1 completed delivery in the
      90 days before each week_start.
    - vertical: standard brand grouping by country_code. See CASE
      statement below — use this instead of entity fields.
    - special_hours uses peak_time from rider_kpi. Only consistently
      populated for Talabat UAE and some gv-* markets.

  VERTICAL CLASSIFICATION (country_code based):
    Pandora      → bd,hk,kh,la,mm,my,ph,pk,sg,tw,at,ca,de,fi,
                   no,se,sk,tr,t3,cz,hu,vn
    Talabat      → ae,bh,eg,iq,jo,kw,om,qa
    Hungerstation → sa
    PedidosYa    → ar,bo,cl,cr,do,ec,gt,hn,ni,py,pe,sv,uy,ve,pa
    Glovo        → all gv-*
    Other        → everything else
    EXCLUDED     → de2 (test country)

  CANARY TAGS (city_id based):
    SA  209       → Hungerstation
    EC  1, 2      → PedidosYa
    PH  1, 3      → Pandora
    AE  201, 202  → Talabat UAE
    OM  211       → Talabat Oman
    gv-*          → Glovo (commented out — canary cities not yet defined)

  CREATED: 2026-05-18
====================================================================*/

CREATE OR REPLACE TABLE `logistics-data-storage-staging.Maripaz.m1_kpi_weekly`
PARTITION BY week_start
CLUSTER BY country_code, city_id
OPTIONS(
  description = "Weekly KPI summary per city. All countries (excl. de2). Rebuilt every Monday. 2-year window.",
  labels = [("owner", "maripaz"), ("theme", "loyalty_m1")]
)
AS

WITH

-- ---------------------------------------------------------------
-- STEP 1: Region lookup
-- Regions: Americas, Asia, Australia, Europe, MENA, Others
-- ---------------------------------------------------------------
country_dim AS (
  SELECT
    country_code,
    region,
    region_short_name
  FROM `fulfillment-dwh-production.cl.countries`
),

-- ---------------------------------------------------------------
-- STEP 2A: Daily rider-level metrics (no unnesting)
-- working_time, planned_working_time, peak_time, tenure are
-- rider-level fields. Unnesting deliveries here would double-count
-- them for riders delivering under multiple entities.
-- de2 excluded (test country).
-- ---------------------------------------------------------------
rider_daily AS (
  SELECT
    created_date_local            AS date,
    country_code,
    city_id,
    city_name,
    rider_id,
    SUM(working_time)             AS working_sec,
    SUM(planned_working_time)     AS planned_sec,
    SUM(peak_time)                AS peak_sec,
    AVG(tenure_in_weeks)          AS tenure_weeks
  FROM `fulfillment-dwh-production.cl.rider_kpi`
  WHERE created_date_local >= DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 2 YEAR)
    AND created_date_local <  DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY))
    AND planned_working_time > 0
    AND country_code != 'de2'
  GROUP BY 1, 2, 3, 4, 5
),

-- ---------------------------------------------------------------
-- STEP 2B: Daily entity-level metrics (unnest deliveries)
-- AR numerator/denominator, completed and cancelled deliveries.
-- Summed across all entities per rider per day.
-- de2 excluded (test country).
-- ---------------------------------------------------------------
delivery_daily AS (
  SELECT
    r.created_date_local          AS date,
    r.country_code,
    r.city_id,
    r.rider_id,
    SUM(d.actual_rider_accepted)  AS accepted,
    SUM(d.manual_undispatched)    AS undispatched,
    SUM(d.actual_rider_notified)  AS notified,
    SUM(d.completed_deliveries)   AS completed,
    SUM(d.cancelled_deliveries)   AS cancelled
  FROM `fulfillment-dwh-production.cl.rider_kpi` r,
    UNNEST(r.deliveries) AS d
  WHERE r.created_date_local >= DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 2 YEAR)
    AND r.created_date_local <  DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY))
    AND d.actual_rider_notified > 0
    AND r.country_code != 'de2'
  GROUP BY 1, 2, 3, 4
),

-- ---------------------------------------------------------------
-- STEP 3: Join rider and delivery at rider-day level
-- Only keep riders with both shift data AND delivery activity.
-- ---------------------------------------------------------------
rider_city_day AS (
  SELECT
    rd.date,
    rd.country_code,
    rd.city_id,
    rd.city_name,
    rd.rider_id,
    rd.working_sec,
    rd.planned_sec,
    rd.peak_sec,
    rd.tenure_weeks,
    dd.accepted,
    dd.undispatched,
    dd.notified,
    dd.completed,
    dd.cancelled
  FROM rider_daily rd
  JOIN delivery_daily dd
    ON  rd.date         = dd.date
    AND rd.country_code = dd.country_code
    AND rd.city_id      = dd.city_id
    AND rd.rider_id     = dd.rider_id
),

-- ---------------------------------------------------------------
-- STEP 4: Active riders in the 90 days prior to each week
-- de2 excluded.
-- ---------------------------------------------------------------
rider_activity AS (
  SELECT DISTINCT
    r.country_code,
    r.city_id,
    r.rider_id,
    DATE_TRUNC(r.created_date_local, WEEK(MONDAY)) AS activity_week
  FROM `fulfillment-dwh-production.cl.rider_kpi` r,
    UNNEST(r.deliveries) AS d
  WHERE d.completed_deliveries > 0
    AND r.created_date_local >= DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 2 YEAR)
    AND r.created_date_local <  DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY))
    AND r.country_code != 'de2'
),

all_weeks AS (
  SELECT DISTINCT DATE_TRUNC(date, WEEK(MONDAY)) AS week_start
  FROM rider_city_day
),

active_90d AS (
  SELECT
    w.week_start,
    a.country_code,
    a.city_id,
    COUNT(DISTINCT a.rider_id) AS active_riders_90d
  FROM all_weeks w
  JOIN rider_activity a
    ON  a.activity_week >= DATE_SUB(w.week_start, INTERVAL 13 WEEK)
    AND a.activity_week <  w.week_start
  GROUP BY 1, 2, 3
),

-- ---------------------------------------------------------------
-- STEP 5: Aggregate to city-week — DATE_TRUNC happens here
-- vertical: standard brand classification by country_code.
-- ---------------------------------------------------------------
weekly_agg AS (
  SELECT
    DATE_TRUNC(rcd.date, WEEK(MONDAY))              AS week_start,
    rcd.country_code,
    rcd.city_id,
    MAX(rcd.city_name)                              AS city_name,

    -- Standard vertical classification (brand grouping by country_code)
    CASE
      WHEN rcd.country_code IN (
        'bd','hk','kh','la','mm','my','ph','pk','sg','tw',
        'at','ca','de','fi','no','se',
        'sk','tr','t3','cz','hu','vn'
      ) THEN 'Pandora'
      WHEN rcd.country_code IN ('ae','bh','eg','iq','jo','kw','om','qa') THEN 'Talabat'
      WHEN rcd.country_code = 'sa'                                        THEN 'Hungerstation'
      WHEN rcd.country_code IN (
        'ar','bo','cl','cr','do','ec','gt','hn','ni','py','pe','sv','uy','ve','pa'
      ) THEN 'PedidosYa'
      WHEN STARTS_WITH(rcd.country_code, 'gv-')                          THEN 'Glovo'
      ELSE 'Other'
    END                                             AS vertical,

    -- Canary tag: identifies Milestone 1 pilot cities. NULL = not canary.
    CASE
      WHEN rcd.country_code = 'sa' AND rcd.city_id = 209         THEN 'Hungerstation'
      WHEN rcd.country_code = 'ec' AND rcd.city_id IN (1, 2)     THEN 'PedidosYa'
      WHEN rcd.country_code = 'ph' AND rcd.city_id IN (1, 3)     THEN 'Pandora'
      WHEN rcd.country_code = 'ae' AND rcd.city_id IN (201, 202) THEN 'Talabat UAE'
      WHEN rcd.country_code = 'om' AND rcd.city_id = 211         THEN 'Talabat Oman'
      -- WHEN STARTS_WITH(rcd.country_code, 'gv-') THEN 'Glovo'  -- Glovo canary cities not yet defined
      ELSE NULL
    END                                             AS canary_tag,

    MAX(cd.region)                                  AS region,
    MAX(cd.region_short_name)                       AS region_short_name,

    COUNT(DISTINCT rcd.rider_id)                    AS working_riders,

    -- KPI 1: Acceptance Rate (fleet-level: sum numerator / sum denominator)
    ROUND(SAFE_DIVIDE(
      SUM(rcd.accepted - rcd.undispatched),
      NULLIF(SUM(rcd.notified), 0)
    ) * 100, 2)                                     AS acceptance_rate_pct,

    -- KPI 2: Plan vs. Actual Hours
    ROUND(SAFE_DIVIDE(
      SUM(rcd.working_sec),
      NULLIF(SUM(rcd.planned_sec), 0)
    ) * 100, 2)                                     AS plan_vs_actual_pct,

    -- KPI 3: Deliveries per Rider (total completions / unique riders this week)
    ROUND(SAFE_DIVIDE(
      SUM(rcd.completed),
      COUNT(DISTINCT rcd.rider_id)
    ), 2)                                           AS deliveries_per_rider,

    -- KPI 4: Average Tenure (weighted by active days)
    ROUND(AVG(rcd.tenure_weeks), 1)                 AS avg_tenure_weeks,

    -- KPI 5: Special Hours per Rider (peak demand hours / unique riders)
    -- NOTE: peak_time only reliably populated for Talabat UAE and some gv-* markets.
    ROUND(SAFE_DIVIDE(
      SUM(rcd.peak_sec) / 3600,
      COUNT(DISTINCT rcd.rider_id)
    ), 2)                                           AS special_hours_per_rider,

    -- KPI 6: Order Completion Rate
    ROUND(SAFE_DIVIDE(
      SUM(rcd.completed),
      NULLIF(SUM(rcd.completed + rcd.cancelled), 0)
    ) * 100, 2)                                     AS order_completion_pct

  FROM rider_city_day rcd
  LEFT JOIN country_dim cd
    ON  rcd.country_code = cd.country_code
  GROUP BY 1, 2, 3, 5, 6  -- 5 = vertical, 6 = canary_tag expressions
),

-- ---------------------------------------------------------------
-- STEP 6: Attach 90-day active rider count
-- ---------------------------------------------------------------
with_90d AS (
  SELECT
    wa.*,
    COALESCE(a.active_riders_90d, 0) AS active_riders_90d
  FROM weekly_agg wa
  LEFT JOIN active_90d a
    ON  wa.week_start   = a.week_start
    AND wa.country_code = a.country_code
    AND wa.city_id      = a.city_id
)

-- ---------------------------------------------------------------
-- STEP 7: Self-join for WoW and MoM deltas
-- WoW: compares to the week starting exactly 7 days prior.
-- MoM: compares to the week containing the date 30 days prior
--      (DATE_TRUNC of week_start - 30 days). Intentionally 30 days,
--      not 4 weeks (28 days).
-- ---------------------------------------------------------------
SELECT
  curr.week_start,
  curr.country_code,
  curr.city_id,
  curr.city_name,
  curr.vertical,
  curr.canary_tag,
  curr.region,
  curr.region_short_name,
  curr.working_riders,
  curr.active_riders_90d,

  -- Raw KPI values
  curr.acceptance_rate_pct,
  curr.plan_vs_actual_pct,
  curr.deliveries_per_rider,
  curr.avg_tenure_weeks,
  curr.special_hours_per_rider,
  curr.order_completion_pct,

  -- WoW absolute deltas (7-day comparison)
  ROUND(curr.acceptance_rate_pct  - wow.acceptance_rate_pct,  2) AS ar_wow_delta,
  ROUND(curr.plan_vs_actual_pct   - wow.plan_vs_actual_pct,   2) AS avp_wow_delta,
  ROUND(curr.deliveries_per_rider - wow.deliveries_per_rider, 2) AS deliveries_wow_delta,
  ROUND(curr.avg_tenure_weeks     - wow.avg_tenure_weeks,     1) AS tenure_wow_delta,
  ROUND(curr.order_completion_pct - wow.order_completion_pct, 2) AS completion_wow_delta,

  -- MoM absolute deltas (30-day comparison)
  ROUND(curr.acceptance_rate_pct  - mom.acceptance_rate_pct,  2) AS ar_mom_delta,
  ROUND(curr.plan_vs_actual_pct   - mom.plan_vs_actual_pct,   2) AS avp_mom_delta,
  ROUND(curr.deliveries_per_rider - mom.deliveries_per_rider, 2) AS deliveries_mom_delta,
  ROUND(curr.avg_tenure_weeks     - mom.avg_tenure_weeks,     1) AS tenure_mom_delta,
  ROUND(curr.order_completion_pct - mom.order_completion_pct, 2) AS completion_mom_delta,

  -- WoW % change
  ROUND(SAFE_DIVIDE(curr.acceptance_rate_pct  - wow.acceptance_rate_pct,  wow.acceptance_rate_pct)  * 100, 1) AS ar_wow_pct_chg,
  ROUND(SAFE_DIVIDE(curr.plan_vs_actual_pct   - wow.plan_vs_actual_pct,   wow.plan_vs_actual_pct)   * 100, 1) AS avp_wow_pct_chg,
  ROUND(SAFE_DIVIDE(curr.deliveries_per_rider - wow.deliveries_per_rider, wow.deliveries_per_rider) * 100, 1) AS deliveries_wow_pct_chg,
  ROUND(SAFE_DIVIDE(curr.order_completion_pct - wow.order_completion_pct, wow.order_completion_pct) * 100, 1) AS completion_wow_pct_chg,

  -- MoM % change
  ROUND(SAFE_DIVIDE(curr.acceptance_rate_pct  - mom.acceptance_rate_pct,  mom.acceptance_rate_pct)  * 100, 1) AS ar_mom_pct_chg,
  ROUND(SAFE_DIVIDE(curr.plan_vs_actual_pct   - mom.plan_vs_actual_pct,   mom.plan_vs_actual_pct)   * 100, 1) AS avp_mom_pct_chg,
  ROUND(SAFE_DIVIDE(curr.deliveries_per_rider - mom.deliveries_per_rider, mom.deliveries_per_rider) * 100, 1) AS deliveries_mom_pct_chg,
  ROUND(SAFE_DIVIDE(curr.order_completion_pct - mom.order_completion_pct, mom.order_completion_pct) * 100, 1) AS completion_mom_pct_chg

FROM with_90d curr

-- WoW: previous Monday (exactly 7 days back)
LEFT JOIN with_90d wow
  ON  curr.country_code = wow.country_code
  AND curr.city_id      = wow.city_id
  AND wow.week_start    = DATE_SUB(curr.week_start, INTERVAL 7 DAY)

-- MoM: the Monday of the week containing the date 30 days ago
LEFT JOIN with_90d mom
  ON  curr.country_code = mom.country_code
  AND curr.city_id      = mom.city_id
  AND mom.week_start    = DATE_TRUNC(DATE_SUB(curr.week_start, INTERVAL 30 DAY), WEEK(MONDAY))
