/*====================================================================
  TABLE: logistics-data-storage-staging.Maripaz.threshold_tool_rider_weekly
====================================================================
  PURPOSE:
    Rider-level weekly KPI table for the Milestone 1 Threshold
    Recommendation Tool. One row per rider × city × week.
    Used to compute percentile distributions so the tool can
    recommend thresholds for any target batch size.

  GRAIN: country_code + city_id + rider_id + week_start (Monday)

  REFRESH: Daily via BQ Scheduled Query (full 12-month rebuild).

  KPIs INCLUDED (Tenure excluded by design):
    Column names and units aligned with Rooster (m1_threshold_base_calculation)
    so both tables can be unioned for countries not yet in Rooster.

    1. acceptance_rate      — AR (accepted − undispatched) / notified  [proportion 0–1]
    2. avp_hours            — AvP working / planned                    [proportion 0–1]
    3. hours                — Total hours logged per week (also used for segmentation)
    4. deliveries           — Completed deliveries per week
    5. utr                  — Deliveries per working hour
    6. special_hours        — Hours worked within special-hour windows.
                              Computed from shifts × break_time intersection,
                              NOT from rider_kpi.peak_time (unreliable for
                              Pandora and other non-Talabat markets).
                              Cities with no windows configured → 0.
                              For launched Milestone 1 cities (any city with
                              a Rooster threshold config — see LAUNCHED CITIES
                              below), weeks from 2026-08-03 onward use the
                              live Rooster config instead of the legacy
                              _scoring_settings source (see KEY DESIGN NOTES).
    7. no_show              — Count of unexcused no-show shifts
    8. late_login           — Count of late-login shifts. Threshold sourced per city
                              from rooster_scoring_scoring_settings (fallback: 300s / 5 min).
    9. batch                — Rooster shift batch number the rider belonged to during
                              that week (from _batch_change_calculation, matched on
                              week_start BETWEEN active_from_date AND active_until_date).
                              'No batch' when the rider had no batch or batch_number IS NULL.

  NOTES:
    - Special hours use the CURRENT active _scoring_settings config
      (is_active = TRUE) applied to all historical shifts. Config
      changes during the 12-month window are not tracked.
    - Overnight shifts are anchored to their created_date, but the
      post-midnight portion of the shift can fall in the NEXT
      calendar day's window (e.g. a 00:00-02:00 window). Fixed
      2026-09-01: special hours now check each shift against both
      its own calendar day and the following day (see shift_days
      below) so this overlap is no longer dropped. Validated against
      sa/209, where every special window includes 00:00, and the
      unfixed version undercounted virtually every rider to 0.
    - de2 excluded (test country).
    - Only riders with ≥1 completed delivery in the week appear.
      Pure no-show weeks are excluded by design.

  KEY DESIGN NOTES:
    - special_hours uses the shifts table (actual_start_at / actual_end_at
      minus break_time) intersected with special-hour windows.
      Do NOT replace with rider_kpi.peak_time — validated as unreliable
      for Pandora/MY markets (see diagnostic query 2026-06-02).
    - special_hours has TWO sources, chosen per (city, week):
        1. Legacy: _scoring_settings, is_active = TRUE, applied as a
           single current snapshot to all historical shifts (config
           changes over the 12-month window are not tracked). Used for
           all cities/weeks not covered by source 2 below.
        2. Rooster live config (rooster_scoring_scoring_settings_threshold
           + rooster_scoring_special_hour_threshold): used ONLY for
           "launched cities" (any country+city_id with a Rooster
           threshold config — currently AR/253, EC/22, GV-UG/1, PH/328,
           SA/209; de2 test country excluded) AND only for weeks from
           2026-08-03 onward. This source IS date-versioned — each
           shift is matched against whichever config version was active
           on that date (see launched_city_config_ranges), since Rooster
           configs change more often than the legacy per-country ones.
           It also applies excused_breaks_in_minutes per window (forgives
           that many minutes of break overlap before subtracting it;
           SA currently uses 10 min, other launched cities use 0).
        The Rooster table is an edit-log (a new row per admin edit, and
        the same effective start_date can have several superseding
        rows), so only the latest-edited version per (country, city_id,
        start_date) is kept before building date ranges.
    - No-show and late login come from the shifts table, not rider_kpi,
      so they capture scheduled-but-missed shifts correctly.

  CANARY TAGS (city_id based):
    SA  209       → Hungerstation
    EC  1, 2      → PedidosYa
    PH  1, 3      → Pandora
    AE  201, 202  → Talabat UAE
    OM  211       → Talabat Oman

  VERTICAL CLASSIFICATION (same as m1_kpi_weekly):
    Pandora       → bd,hk,kh,la,mm,my,ph,pk,sg,tw,at,ca,de,fi,no,se,sk,tr,t3,cz,hu,vn
    Talabat       → ae,bh,eg,iq,jo,kw,om,qa
    Hungerstation → sa
    PedidosYa     → ar,bo,cl,cr,do,ec,gt,hn,ni,py,pe,sv,uy,ve,pa
    Glovo         → all gv-*
    Other         → everything else

  CREATED: 2026-06-02
  UPDATED: 2026-08-27 — added Rooster live special_hours source for
    launched Milestone 1 cities, from week 2026-08-03 onward.
  UPDATED: 2026-09-01 — fixed overnight-shift midnight-crossing bug in
    special_hours (both legacy and Rooster-live sources): the
    post-midnight portion of a shift is now checked against the
    following calendar day's window instead of being silently dropped.
====================================================================*/

CREATE OR REPLACE TABLE `logistics-data-storage-staging.Maripaz.threshold_tool_rider_weekly`
PARTITION BY week_start
CLUSTER BY country_code, city_id, rider_id
OPTIONS(
  description = "Rider-level weekly KPI table for Milestone 1 threshold recommendation tool. One row per rider × city × week. 12-month rolling window rebuilt daily.",
  labels = [("owner", "maripaz"), ("theme", "loyalty_m1")]
)
AS

WITH

-- ---------------------------------------------------------------
-- STEP 1: Country dimension (region lookup)
-- ---------------------------------------------------------------
country_dim AS (
  SELECT country_code, region, region_short_name
  FROM `fulfillment-dwh-production.cl.countries`
),

-- ---------------------------------------------------------------
-- STEP 2: Active special hours windows per city
-- Source: _scoring_settings, is_active = TRUE only.
-- day_of_week: 0 = Monday … 6 = Sunday (scoring_settings convention)
-- ---------------------------------------------------------------
special_hours_config AS (
  SELECT
    ss.country_code,
    ss.city_id,
    sh.day_of_week,
    sh.from_hour,
    sh.to_hour
  FROM `fulfillment-dwh-production.cl._scoring_settings` ss,
    UNNEST(ss.scoring_settings) AS s,
    UNNEST(s.special_hour)      AS sh
  WHERE s.is_active = TRUE
),

-- ---------------------------------------------------------------
-- STEP 2B: Rooster live special-hours config for LAUNCHED cities
-- Source: rooster_scoring_scoring_settings_threshold (parent config,
-- date-versioned) + rooster_scoring_special_hour_threshold (windows).
-- "Launched" = any (country, city_id) that has ever had a Milestone 1
-- threshold config configured in Rooster (test country de2 excluded).
--
-- This table is an edit-log: the same effective start_date can have
-- several superseding rows (re-saves before/after it took effect), so
-- we keep only the latest-edited version per (country, city_id,
-- start_date), then turn the ordered start_dates into non-overlapping
-- [active_from_date, active_until_date] ranges so each historical
-- shift can be matched to the config that was actually active then.
-- ---------------------------------------------------------------
launched_city_config_versions AS (
  SELECT
    country AS country_code,
    city_id,
    id       AS config_id,
    start_date
  FROM `fulfillment-dwh-production.dl.rooster_scoring_scoring_settings_threshold`
  WHERE country != 'de2'
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY country, city_id, start_date
    ORDER BY updated_at DESC, id DESC
  ) = 1
),

launched_city_config_ranges AS (
  SELECT
    country_code,
    city_id,
    config_id,
    start_date                                            AS active_from_date,
    IFNULL(
      DATE_SUB(
        LEAD(start_date) OVER (PARTITION BY country_code, city_id ORDER BY start_date),
        INTERVAL 1 DAY
      ),
      DATE '9999-12-31'
    )                                                      AS active_until_date
  FROM launched_city_config_versions
),

launched_cities AS (
  SELECT DISTINCT country_code, city_id
  FROM launched_city_config_ranges
),

-- day_of_week mapping from Rooster's STRING convention to the same
-- 0=Mon..6=Sun convention used by special_hours_config above.
special_hours_config_new AS (
  SELECT DISTINCT
    r.country_code,
    r.city_id,
    r.active_from_date,
    r.active_until_date,
    CASE h.day_of_week
      WHEN 'MONDAY'    THEN 0
      WHEN 'TUESDAY'   THEN 1
      WHEN 'WEDNESDAY' THEN 2
      WHEN 'THURSDAY'  THEN 3
      WHEN 'FRIDAY'    THEN 4
      WHEN 'SATURDAY'  THEN 5
      WHEN 'SUNDAY'    THEN 6
    END                                                    AS day_of_week,
    h.from_hour,
    h.to_hour,
    IFNULL(h.excused_breaks_in_minutes, 0)                 AS excused_breaks_in_minutes
  FROM launched_city_config_ranges r
  JOIN `fulfillment-dwh-production.dl.rooster_scoring_special_hour_threshold` h
    ON h.scoring_settings_threshold_id = r.config_id
),

-- ---------------------------------------------------------------
-- STEP 3A: Daily rider-level metrics (no unnesting)
-- working_time and planned_working_time are rider-level fields.
-- ---------------------------------------------------------------
rider_daily AS (
  SELECT
    created_date_local          AS date,
    country_code,
    city_id,
    city_name,
    rider_id,
    SUM(working_time)           AS working_sec,
    SUM(planned_working_time)   AS planned_sec
  FROM `fulfillment-dwh-production.cl.rider_kpi`
  WHERE created_date_local >= DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 52 WEEK)
    AND created_date_local <  DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY))
    AND planned_working_time > 0
    AND country_code != 'de2'
  GROUP BY 1, 2, 3, 4, 5
),

-- ---------------------------------------------------------------
-- STEP 3B: Daily delivery metrics (unnest deliveries)
-- Summed across all entities per rider per day.
-- ---------------------------------------------------------------
delivery_daily AS (
  SELECT
    r.created_date_local        AS date,
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
  WHERE r.created_date_local >= DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 52 WEEK)
    AND r.created_date_local <  DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY))
    AND d.actual_rider_notified > 0
    AND r.country_code != 'de2'
  GROUP BY 1, 2, 3, 4
),

-- ---------------------------------------------------------------
-- STEP 4: Join rider and delivery at rider-city-day grain
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
-- STEP 5: Special hours — intersection of actual shift time
-- (minus breaks) with the scoring_settings special hour windows.
--
-- day_of_week mapping from BQ to scoring_settings convention:
--   BQ EXTRACT(DAYOFWEEK): 1=Sun, 2=Mon, … 7=Sat
--   scoring_settings:      0=Mon, 1=Tue, … 6=Sun
--   Formula: MOD(EXTRACT(DAYOFWEEK FROM date) + 5, 7)
--
-- Shifts spanning midnight are anchored to their created_date, but the
-- post-midnight portion can fall in the NEXT day's window (e.g. a
-- 00:00-02:00 window). shift_days below checks each shift against
-- both its own calendar day and the following day so that overlap
-- isn't lost.
-- ---------------------------------------------------------------
shifts_base AS (
  SELECT
    s.country_code,
    s.city_id,
    s.rider_id,
    s.created_date                                         AS shift_date,
    s.timezone,
    DATETIME(s.actual_start_at, s.timezone)               AS actual_start_local,
    DATETIME(s.actual_end_at,   s.timezone)               AS actual_end_local,
    s.break_time
  FROM `fulfillment-dwh-production.cl.shifts` s
  WHERE s.created_date >= DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 52 WEEK)
    AND s.created_date <  DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY))
    AND s.shift_state NOT IN ('CANCELLED', 'NO_SHOW', 'NO_SHOW_EXCUSED')
    AND s.actual_start_at IS NOT NULL
    AND s.actual_end_at   IS NOT NULL
    AND s.country_code != 'de2'
),

-- FIX (2026-09-01): pair each shift with its own calendar day AND the
-- following day. The two windows are disjoint in time (GREATEST/LEAST
-- floor non-overlapping days to 0 net_overlap_sec below), so summing
-- across both is safe and never double-counts.
shift_days AS (
  SELECT sb.*, DATE_ADD(sb.shift_date, INTERVAL day_offset DAY) AS calendar_day
  FROM shifts_base sb, UNNEST([0, 1]) AS day_offset
),

special_hours_shifts AS (
  SELECT
    sd.country_code,
    sd.city_id,
    sd.rider_id,
    sd.calendar_day                                        AS shift_date,
    -- Gross overlap: actual shift interval vs special hours window
    GREATEST(0,
      DATETIME_DIFF(
        LEAST(sd.actual_end_local,   DATETIME(sd.calendar_day, shc.to_hour)),
        GREATEST(sd.actual_start_local, DATETIME(sd.calendar_day, shc.from_hour)),
        SECOND
      )
    )
    -- Subtract break time that falls within the same window
    - (
        SELECT IFNULL(SUM(
          GREATEST(0,
            DATETIME_DIFF(
              LEAST(b.end_at_local,     DATETIME(sd.calendar_day, shc.to_hour)),
              GREATEST(b.start_at_local,  DATETIME(sd.calendar_day, shc.from_hour)),
              SECOND
            )
          )
        ), 0)
        FROM UNNEST(sd.break_time) b
        WHERE b.start_at_local IS NOT NULL
          AND b.end_at_local   IS NOT NULL
    )                                                     AS net_overlap_sec
  FROM shift_days sd
  JOIN special_hours_config shc
    ON  sd.country_code = shc.country_code
    AND sd.city_id      = shc.city_id
    AND MOD(EXTRACT(DAYOFWEEK FROM sd.calendar_day) + 5, 7) = shc.day_of_week
),

special_hours_daily AS (
  SELECT
    country_code,
    city_id,
    rider_id,
    shift_date                                            AS date,
    SUM(GREATEST(0, net_overlap_sec))                     AS special_hours_sec
  FROM special_hours_shifts
  GROUP BY 1, 2, 3, 4
),

-- ---------------------------------------------------------------
-- STEP 5A-NEW: Special hours for launched cities — Rooster live config
-- Same shift/break intersection method as special_hours_shifts above,
-- but matched to the config version active on each shift's date
-- (launched_city_config_ranges) rather than a single current snapshot,
-- and only computed from 2026-08-03 onward (see final SELECT for the
-- per-city/week cutover logic vs. the legacy source).
-- excused_breaks_in_minutes forgives that many minutes of break-time
-- overlap per shift-window before subtracting it (SA = 10 min today,
-- 0 for other launched cities).
-- ---------------------------------------------------------------
special_hours_shifts_new AS (
  SELECT
    sd.country_code,
    sd.city_id,
    sd.rider_id,
    sd.calendar_day                                        AS shift_date,
    GREATEST(0,
      DATETIME_DIFF(
        LEAST(sd.actual_end_local,   DATETIME(sd.calendar_day, shc.to_hour)),
        GREATEST(sd.actual_start_local, DATETIME(sd.calendar_day, shc.from_hour)),
        SECOND
      )
    )
    - GREATEST(0,
        (
          SELECT IFNULL(SUM(
            GREATEST(0,
              DATETIME_DIFF(
                LEAST(b.end_at_local,     DATETIME(sd.calendar_day, shc.to_hour)),
                GREATEST(b.start_at_local,  DATETIME(sd.calendar_day, shc.from_hour)),
                SECOND
              )
            )
          ), 0)
          FROM UNNEST(sd.break_time) b
          WHERE b.start_at_local IS NOT NULL
            AND b.end_at_local   IS NOT NULL
        ) - shc.excused_breaks_in_minutes * 60
      )                                                    AS net_overlap_sec
  FROM shift_days sd
  JOIN special_hours_config_new shc
    ON  sd.country_code = shc.country_code
    AND sd.city_id      = shc.city_id
    -- Config-version selection stays keyed to the shift's own date
    -- (when it was scheduled), not calendar_day (used for window
    -- overlap above) — those are two different questions.
    AND sd.shift_date BETWEEN shc.active_from_date AND shc.active_until_date
    AND MOD(EXTRACT(DAYOFWEEK FROM sd.calendar_day) + 5, 7) = shc.day_of_week
  WHERE sd.shift_date >= DATE '2026-08-03'
),

special_hours_daily_new AS (
  SELECT
    country_code,
    city_id,
    rider_id,
    shift_date                                            AS date,
    SUM(GREATEST(0, net_overlap_sec))                     AS special_hours_sec
  FROM special_hours_shifts_new
  GROUP BY 1, 2, 3, 4
),

-- ---------------------------------------------------------------
-- STEP 5B: Late-login threshold per city from Rooster config
-- Source: rooster_scoring_scoring_settings, active configs only.
-- Threshold varies by city (1, 5, 7, 10, 15, 30 min are common).
-- Fallback: 300s (5 min) for cities not configured in Rooster.
-- ---------------------------------------------------------------
late_login_config AS (
  SELECT
    country                   AS country_code,
    city_id,
    late_login_minutes * 60   AS late_login_seconds
  FROM `fulfillment-dwh-production.dl.rooster_scoring_scoring_settings`
  WHERE active = TRUE
  QUALIFY ROW_NUMBER() OVER (PARTITION BY country, city_id ORDER BY updated_at DESC) = 1
),

-- ---------------------------------------------------------------
-- STEP 6: Shift KPIs — no-show and late login per rider per day
-- Source: shifts table (captures no-shows unlike rider_kpi).
-- Late login threshold: per-city from rooster_scoring_scoring_settings.
-- Fallback 300s (5 min) for cities not in Rooster.
-- ---------------------------------------------------------------
shift_kpis_daily AS (
  SELECT
    s.country_code,
    s.city_id,
    s.rider_id,
    s.created_date                                        AS date,
    -- Only unexcused no-shows count against riders (NO_SHOW_EXCUSED excluded from numerator)
    COUNTIF(s.shift_state = 'NO_SHOW')                    AS no_show_count,
    COUNTIF(
      s.shift_state NOT IN ('NO_SHOW', 'NO_SHOW_EXCUSED')
      AND s.actual_start_at IS NOT NULL
      AND s.login_difference > IFNULL(ll.late_login_seconds, 300)
    )                                                     AS late_login_count,
    -- Denominator: all non-cancelled shifts (including no-shows of both types)
    COUNT(*)                                              AS total_shifts
  FROM `fulfillment-dwh-production.cl.shifts` s
  LEFT JOIN late_login_config ll
    ON  s.city_id      = ll.city_id
    AND s.country_code = ll.country_code
  WHERE s.created_date >= DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 52 WEEK)
    AND s.created_date <  DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY))
    AND s.shift_state != 'CANCELLED'
    AND s.country_code != 'de2'
  GROUP BY 1, 2, 3, 4
),

-- ---------------------------------------------------------------
-- STEP 7: Aggregate to rider × week
-- ---------------------------------------------------------------
rider_week AS (
  SELECT
    DATE_TRUNC(date, WEEK(MONDAY))   AS week_start,
    country_code,
    city_id,
    MAX(city_name)                    AS city_name,
    rider_id,
    SUM(working_sec)                  AS total_working_sec,
    SUM(planned_sec)                  AS total_planned_sec,
    SUM(accepted - undispatched)      AS total_accepted,
    SUM(notified)                     AS total_notified,
    SUM(completed)                    AS total_completed
  FROM rider_city_day
  GROUP BY 1, 2, 3, 5
),

special_hours_week AS (
  SELECT
    DATE_TRUNC(date, WEEK(MONDAY))   AS week_start,
    country_code,
    city_id,
    rider_id,
    SUM(special_hours_sec) / 3600.0  AS special_hours_worked
  FROM special_hours_daily
  GROUP BY 1, 2, 3, 4
),

special_hours_week_new AS (
  SELECT
    DATE_TRUNC(date, WEEK(MONDAY))   AS week_start,
    country_code,
    city_id,
    rider_id,
    SUM(special_hours_sec) / 3600.0  AS special_hours_worked
  FROM special_hours_daily_new
  GROUP BY 1, 2, 3, 4
),

shift_kpis_week AS (
  SELECT
    DATE_TRUNC(date, WEEK(MONDAY))   AS week_start,
    country_code,
    city_id,
    rider_id,
    SUM(no_show_count)               AS no_show_count,
    SUM(late_login_count)            AS late_login_count,
    SUM(total_shifts)                AS total_shifts
  FROM shift_kpis_daily
  GROUP BY 1, 2, 3, 4
)

-- ---------------------------------------------------------------
-- STEP 8: Final assembly — join all sources, add dimensions
-- ---------------------------------------------------------------
SELECT
  rw.week_start,
  rw.country_code,
  rw.city_id,
  rw.city_name,
  rw.rider_id,

  -- Vertical classification (brand grouping by country_code)
  CASE
    WHEN rw.country_code IN (
      'bd','hk','kh','la','mm','my','ph','pk','sg','tw',
      'at','ca','de','fi','no','se','sk','tr','t3','cz','hu','vn'
    ) THEN 'Pandora'
    WHEN rw.country_code IN ('ae','bh','eg','iq','jo','kw','om','qa') THEN 'Talabat'
    WHEN rw.country_code = 'sa'                                        THEN 'Hungerstation'
    WHEN rw.country_code IN (
      'ar','bo','cl','cr','do','ec','gt','hn','ni','py','pe','sv','uy','ve','pa'
    ) THEN 'PedidosYa'
    WHEN STARTS_WITH(rw.country_code, 'gv-')                          THEN 'Glovo'
    ELSE 'Other'
  END                                                                  AS brand,

  -- Canary tag: Milestone 1 pilot cities
  CASE
    WHEN rw.country_code = 'sa' AND rw.city_id = 209             THEN 'Hungerstation'
    WHEN rw.country_code = 'ec' AND rw.city_id IN (1, 2)         THEN 'PedidosYa'
    WHEN rw.country_code = 'ph' AND rw.city_id IN (1, 3)         THEN 'Pandora'
    WHEN rw.country_code = 'ae' AND rw.city_id IN (201, 202)     THEN 'Talabat UAE'
    WHEN rw.country_code = 'om' AND rw.city_id = 211             THEN 'Talabat Oman'
    ELSE NULL
  END                                                                  AS canary_tag,

  cd.region,
  cd.region_short_name,

  -- KPI 1: Acceptance Rate [proportion 0–1, aligned with Rooster ACCEPTANCE]
  ROUND(SAFE_DIVIDE(
    rw.total_accepted,
    NULLIF(rw.total_notified, 0)
  ), 4)                                                                AS acceptance_rate,

  -- KPI 2: Plan vs Actual Hours [proportion 0–1, aligned with Rooster ACTUAL_TO_PLANNED_HOURS]
  -- Capped at 1.0 to match Rooster behaviour (Rooster does not allow >100% plan adherence)
  ROUND(LEAST(SAFE_DIVIDE(
    rw.total_working_sec,
    NULLIF(rw.total_planned_sec, 0)
  ), 1.0), 4)                                                          AS avp_hours,

  -- KPI 3: Working Hours (also used for rider segmentation by working time)
  ROUND(rw.total_working_sec / 3600.0, 2)                             AS hours,

  -- KPI 4: Deliveries (completed)
  rw.total_completed                                                   AS deliveries,

  -- KPI 5: UTR — deliveries per working hour
  ROUND(SAFE_DIVIDE(
    rw.total_completed,
    NULLIF(rw.total_working_sec / 3600.0, 0)
  ), 2)                                                                AS utr,

  -- KPI 6: Special Hours (hours during scoring windows)
  -- Uses shifts-based intersection method. 0 for cities with no windows.
  -- Launched cities (lc) use the live Rooster config (shn) for weeks
  -- from 2026-08-03 onward; everything else falls back to the legacy
  -- _scoring_settings-based calculation (sh).
  ROUND(
    IF(lc.city_id IS NOT NULL AND rw.week_start >= DATE '2026-08-03',
       IFNULL(shn.special_hours_worked, 0),
       IFNULL(sh.special_hours_worked, 0)
    ), 2)                                                              AS special_hours,

  -- KPI 7: No-show count [aligned with Rooster NO_SHOW absolute_value]
  IFNULL(sk.no_show_count, 0)                                         AS no_show,

  -- KPI 8: Late-login count [aligned with Rooster LATE_LOGIN absolute_value]
  -- Late = login_difference > 300s (5 min).
  IFNULL(sk.late_login_count, 0)                                      AS late_login,

  -- Batch: Rooster shift batch the rider was in during this week.
  -- batch_number IS NULL in source means rider has no batch assigned.
  IFNULL(CAST(bc.batch_number AS STRING), 'No batch')                 AS batch

FROM rider_week rw
LEFT JOIN special_hours_week sh
  ON  rw.week_start   = sh.week_start
  AND rw.country_code = sh.country_code
  AND rw.city_id      = sh.city_id
  AND rw.rider_id     = sh.rider_id
LEFT JOIN special_hours_week_new shn
  ON  rw.week_start   = shn.week_start
  AND rw.country_code = shn.country_code
  AND rw.city_id      = shn.city_id
  AND rw.rider_id     = shn.rider_id
LEFT JOIN launched_cities lc
  ON  rw.country_code = lc.country_code
  AND rw.city_id      = lc.city_id
LEFT JOIN shift_kpis_week sk
  ON  rw.week_start   = sk.week_start
  AND rw.country_code = sk.country_code
  AND rw.city_id      = sk.city_id
  AND rw.rider_id     = sk.rider_id
LEFT JOIN country_dim cd
  ON  rw.country_code = cd.country_code
LEFT JOIN `fulfillment-dwh-production.cl._batch_change_calculation` bc
  ON  bc.country_code  = rw.country_code
  AND bc.rider_id      = rw.rider_id
  AND rw.week_start   >= bc.active_from_date
  AND rw.week_start   <= bc.active_until_date
