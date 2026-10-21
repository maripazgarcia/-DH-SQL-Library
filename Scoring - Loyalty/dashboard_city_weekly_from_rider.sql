/*====================================================================
  QUERY: Dashboard — City-Week KPIs from threshold_tool_rider_weekly
====================================================================
  PURPOSE:
    Data Studio custom query to replace m1_kpi_weekly as the
    dashboard data source. Aggregates rider-level data from
    threshold_tool_rider_weekly up to city × week grain,
    preserving the same column structure as m1_kpi_weekly.

  GRAIN: country_code + city_id + week_start (Monday)

  FIELD MAPPING vs m1_kpi_weekly:
    ✅  working_riders          — same logic
    ✅  acceptance_rate_pct     — AVG of rider-level ratios × 100.
                                  Slight difference from m1_kpi_weekly:
                                  that table used fleet-level SUM(accepted)/SUM(notified);
                                  here it is a simple average across riders (raw
                                  counts not stored in source table).
    ✅  plan_vs_actual_pct      — same note as AR above; already capped at 100%
                                  at rider level in source table.
    ✅  deliveries_per_rider    — SUM(deliveries) / COUNT(DISTINCT rider_id)
    ✅  special_hours_per_rider — BETTER than m1_kpi_weekly; uses shifts-based
                                  intersection (reliable for all markets incl. Pandora).
                                  m1_kpi_weekly used peak_time which was unreliable.
    ✅  utr                     — NEW: fleet-level UTR = SUM(deliveries) / SUM(hours)
    ✅  no_show_per_rider       — NEW: from shifts table
    ✅  late_login_per_rider    — NEW: from shifts table

    ❌  avg_tenure_weeks        — not in source table (tenure not carried through)
    ❌  order_completion_pct    — not in source table (cancelled deliveries not stored)
    ❌  active_riders_90d       — requires expensive self-join; excluded for Data Studio

  WoW / MoM:
    Same logic as m1_kpi_weekly:
    - WoW = current vs week_start - 7 days
    - MoM = current vs DATE_TRUNC(week_start - 30 days, WEEK(MONDAY))

  NOTES FOR DATA STUDIO:
    - Apply a date range filter on week_start to limit scan cost.
    - Self-join for WoW/MoM reads the table 3× per query; add a
      date range parameter or pre-filter with a WHERE on week_start
      if the dashboard is slow.
    - The table is partitioned by week_start — date filters will
      prune partitions and keep costs low.

  SOURCE TABLE:
    logistics-data-storage-staging.Maripaz.threshold_tool_rider_weekly
====================================================================*/

WITH

city_week AS (
  SELECT
    week_start,
    country_code,
    city_id,
    MAX(city_name)                                                    AS city_name,

    -- Brand grouping (called "vertical" in m1_kpi_weekly, "brand" in source)
    MAX(brand)                                                        AS vertical,
    MAX(canary_tag)                                                   AS canary_tag,
    MAX(region)                                                       AS region,
    MAX(region_short_name)                                            AS region_short_name,

    -- Rider count
    COUNT(DISTINCT rider_id)                                          AS working_riders,

    -- KPI 1: Acceptance Rate (simple avg of rider-level proportions)
    -- Note: m1_kpi_weekly used fleet-level weighted average (sum/sum).
    -- Difference is typically <0.5 pp for large cities.
    ROUND(AVG(acceptance_rate) * 100, 2)                             AS acceptance_rate_pct,

    -- KPI 2: Plan vs Actual Hours (simple avg, already capped at 100% per rider)
    ROUND(AVG(avp_hours) * 100, 2)                                   AS plan_vs_actual_pct,

    -- KPI 3: Deliveries per Rider
    ROUND(
      SAFE_DIVIDE(SUM(deliveries), NULLIF(COUNT(DISTINCT rider_id), 0))
    , 2)                                                              AS deliveries_per_rider,

    -- KPI 4: Fleet-level UTR (total deliveries / total working hours)
    ROUND(
      SAFE_DIVIDE(SUM(deliveries), NULLIF(SUM(hours), 0))
    , 2)                                                              AS utr,

    -- KPI 5: Special Hours per Rider
    -- Shifts-based intersection method — reliable for all markets.
    -- Cities with no scoring windows configured → 0.
    ROUND(
      SAFE_DIVIDE(SUM(special_hours), NULLIF(COUNT(DISTINCT rider_id), 0))
    , 2)                                                              AS special_hours_per_rider,

    -- KPI 6: No-show per Rider
    ROUND(
      SAFE_DIVIDE(SUM(no_show), NULLIF(COUNT(DISTINCT rider_id), 0))
    , 2)                                                              AS no_show_per_rider,

    -- KPI 7: Late Login per Rider
    ROUND(
      SAFE_DIVIDE(SUM(late_login), NULLIF(COUNT(DISTINCT rider_id), 0))
    , 2)                                                              AS late_login_per_rider,

    -- Totals (useful for drill-down charts)
    SUM(deliveries)                                                   AS total_deliveries,
    ROUND(SUM(hours), 1)                                             AS total_hours,
    SUM(no_show)                                                      AS total_no_shows,
    SUM(late_login)                                                   AS total_late_logins

  FROM `logistics-data-storage-staging.Maripaz.threshold_tool_rider_weekly`
  GROUP BY 1, 2, 3
)

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

  -- Raw KPI values
  curr.acceptance_rate_pct,
  curr.plan_vs_actual_pct,
  curr.deliveries_per_rider,
  curr.utr,
  curr.special_hours_per_rider,
  curr.no_show_per_rider,
  curr.late_login_per_rider,
  curr.total_deliveries,
  curr.total_hours,
  curr.total_no_shows,
  curr.total_late_logins,

  -- ── WoW absolute deltas ──────────────────────────────────────────
  ROUND(curr.acceptance_rate_pct     - wow.acceptance_rate_pct,     2) AS ar_wow_delta,
  ROUND(curr.plan_vs_actual_pct      - wow.plan_vs_actual_pct,      2) AS avp_wow_delta,
  ROUND(curr.deliveries_per_rider    - wow.deliveries_per_rider,    2) AS deliveries_wow_delta,
  ROUND(curr.utr                     - wow.utr,                     2) AS utr_wow_delta,
  ROUND(curr.special_hours_per_rider - wow.special_hours_per_rider, 2) AS special_hours_wow_delta,
  ROUND(curr.no_show_per_rider       - wow.no_show_per_rider,       2) AS no_show_wow_delta,
  ROUND(curr.late_login_per_rider    - wow.late_login_per_rider,    2) AS late_login_wow_delta,

  -- ── MoM absolute deltas ──────────────────────────────────────────
  ROUND(curr.acceptance_rate_pct     - mom.acceptance_rate_pct,     2) AS ar_mom_delta,
  ROUND(curr.plan_vs_actual_pct      - mom.plan_vs_actual_pct,      2) AS avp_mom_delta,
  ROUND(curr.deliveries_per_rider    - mom.deliveries_per_rider,    2) AS deliveries_mom_delta,
  ROUND(curr.utr                     - mom.utr,                     2) AS utr_mom_delta,
  ROUND(curr.special_hours_per_rider - mom.special_hours_per_rider, 2) AS special_hours_mom_delta,
  ROUND(curr.no_show_per_rider       - mom.no_show_per_rider,       2) AS no_show_mom_delta,
  ROUND(curr.late_login_per_rider    - mom.late_login_per_rider,    2) AS late_login_mom_delta,

  -- ── WoW % changes ────────────────────────────────────────────────
  ROUND(SAFE_DIVIDE(curr.acceptance_rate_pct     - wow.acceptance_rate_pct,     wow.acceptance_rate_pct)     * 100, 1) AS ar_wow_pct_chg,
  ROUND(SAFE_DIVIDE(curr.plan_vs_actual_pct      - wow.plan_vs_actual_pct,      wow.plan_vs_actual_pct)      * 100, 1) AS avp_wow_pct_chg,
  ROUND(SAFE_DIVIDE(curr.deliveries_per_rider    - wow.deliveries_per_rider,    wow.deliveries_per_rider)    * 100, 1) AS deliveries_wow_pct_chg,
  ROUND(SAFE_DIVIDE(curr.utr                     - wow.utr,                     wow.utr)                     * 100, 1) AS utr_wow_pct_chg,
  ROUND(SAFE_DIVIDE(curr.special_hours_per_rider - wow.special_hours_per_rider, wow.special_hours_per_rider) * 100, 1) AS special_hours_wow_pct_chg,

  -- ── MoM % changes ────────────────────────────────────────────────
  ROUND(SAFE_DIVIDE(curr.acceptance_rate_pct     - mom.acceptance_rate_pct,     mom.acceptance_rate_pct)     * 100, 1) AS ar_mom_pct_chg,
  ROUND(SAFE_DIVIDE(curr.plan_vs_actual_pct      - mom.plan_vs_actual_pct,      mom.plan_vs_actual_pct)      * 100, 1) AS avp_mom_pct_chg,
  ROUND(SAFE_DIVIDE(curr.deliveries_per_rider    - mom.deliveries_per_rider,    mom.deliveries_per_rider)    * 100, 1) AS deliveries_mom_pct_chg,
  ROUND(SAFE_DIVIDE(curr.utr                     - mom.utr,                     mom.utr)                     * 100, 1) AS utr_mom_pct_chg,
  ROUND(SAFE_DIVIDE(curr.special_hours_per_rider - mom.special_hours_per_rider, mom.special_hours_per_rider) * 100, 1) AS special_hours_mom_pct_chg

FROM city_week curr

-- WoW: the week starting exactly 7 days prior
LEFT JOIN city_week wow
  ON  curr.country_code = wow.country_code
  AND curr.city_id      = wow.city_id
  AND wow.week_start    = DATE_SUB(curr.week_start, INTERVAL 7 DAY)

-- MoM: the Monday of the week containing the date 30 days ago
LEFT JOIN city_week mom
  ON  curr.country_code = mom.country_code
  AND curr.city_id      = mom.city_id
  AND mom.week_start    = DATE_TRUNC(DATE_SUB(curr.week_start, INTERVAL 30 DAY), WEEK(MONDAY))

ORDER BY week_start DESC, country_code, city_id
