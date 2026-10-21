-- ============================================================================
-- Milestone 2 Engagement Segmentation Analysis
-- Doc: Knowledge/project_loyalty_tier_m2_engagement_segmentation.md
--
-- Groups riders long-term by trailing 13-week (~3 month) deliveries, per
-- country, into a 4-group split (weighted 10/20/30/40 AND an equal-quartile
-- alternative, both included for comparison) and a 2-group median split.
-- Crosses those long-term groups against the weekly Scoring batch to build
-- the Segment x Batch matrix, and reports:
--   1. % of riders per cell (global, min. 50 riders per cell to display)
--   2. % of deliveries per cell
--   3. % of deliveries made within special hours per cell (exact delivery-
--      grain rebuild — see Table 1)
--   4. 4-week and 12-week retention per group
--   5. Average tenure (since first-ever completed delivery) per group
--   6. Rider-week batch distribution fallback view
--   7. Actual delivery-count cut values at P90/P70/P40, per country + global
--
-- Batch representation: a rider's batch changes weekly, so this produces
-- TWO views:
--   - m2_rider_segments: "last batch" (most recent week in the window) per
--     rider — used for the primary %-riders / %-deliveries / retention /
--     tenure matrix.
--   - m2_rider_week_batches: one row per rider-week, batch that week x the
--     rider's (fixed) long-term group — use this for the rider-week COUNT
--     distribution if "last batch" alone looks too noisy/unrepresentative.
--
-- Sources:
--   logistics-data-storage-staging.Maripaz.threshold_tool_rider_weekly (deliveries)
--   fulfillment-dwh-production.cl.rider_kpi          (batch_number, country coverage check)
--   fulfillment-dwh-production.cl.orders             (special-hours + tenure rebuild)
--   fulfillment-dwh-production.cl._scoring_settings   (special-hours windows)
--
-- Deliveries definition (confirmed 2026-07-15): `deliveries` throughout this
-- pipeline = COMPLETED deliveries, not accepted/notified. Lineage:
-- threshold_tool_rider_weekly.deliveries = rw.total_completed =
-- SUM(rider_kpi.deliveries[].completed_deliveries) — see
-- threshold_tool_rider_weekly.sql STEP 3B/7. Accepted-but-not-completed
-- deliveries are not counted anywhere in this segmentation.
--
-- IMPORTANT — validate before trusting outputs:
--   deliveries_special_hours (Table 1) is rebuilt from `orders.deliveries`
--   (delivery_status='completed', is_primary=TRUE), a DIFFERENT source than
--   `threshold_tool_rider_weekly.deliveries` (which comes from rider_kpi).
--   The two delivery counts may not tie out exactly. Sanity-check them
--   against each other for a sample week/country before trusting
--   pct_deliveries_special_hours.
--
-- Scope decisions locked in for this build (updated 2026-07-15):
--   - Segmentation metric: deliveries count (not orders, not hours) —
--     confirmed COMPLETED deliveries, see lineage note above.
--   - Window: rolling 13 weeks, ending 12 weeks before the latest available
--     week, so 4wk/12wk retention can be measured on already-observed data
--     instead of waiting for the future.
--   - Batch axis: `batch_number` fetched directly from `rider_kpi` (rider-day
--     grain, forward-filled then collapsed to rider-week using the last
--     observed day — see the data-quality warning below on why the forward-
--     fill is required), NOT from `_batch_change_calculation` and NOT from
--     threshold_tool_rider_weekly (validated 2026-07-15 that the deployed
--     table's schema predates the `batch` column added in
--     threshold_tool_rider_weekly.sql — it needs a rerun to pick that up;
--     this script doesn't depend on that rerun).
--   - Country exclusion: a country is dropped from the whole analysis if
--     (a) over the last 12 available weeks more than 90% of its riders show
--     no batch (forward-filled last-known batch_number IS NULL) —
--     auto-detected 2026-07-15: `t5` (~374 riders, trivial); OR (b) the
--     team confirmed it isn't live with Scoring — `at`, `ph` (2026-07-16);
--     OR (c) it is a Glovo market (`gv-*`) — excluded 2026-07-16 because
--     Glovo runs a structurally different ~16-batch near-uniform scoring
--     system (vs ~4-6 batches elsewhere), so "B1-B2" is not comparable and
--     pooling it inflated the non-top-batch headline from 48% to 52%.
--     Glovo is ~10% of deliveries with 85.6% of them in B3+ purely as an
--     artifact of having 16 batch slots. If Glovo needs this analysis it
--     must be done separately with its own batch bucketing. See Table 0.
--   - Percentiles computed PER COUNTRY (a "top 10%" rider means top 10%
--     within their own country's fleet, not globally pooled) — required
--     for the later country-flexibility analysis to be meaningful.
--   - Tenure = weeks since first-ever completed delivery (not account
--     creation date). Lookback bounded to 4 years for cost control —
--     riders whose true first delivery predates that are flagged via
--     tenure_left_censored rather than silently mis-measured.
--   - Minimum cell size: 50 riders. Enforced in the reporting queries at
--     the bottom, not in the base tables (so the raw data stays reusable).
--   - Country cut: none baked in — start global, filter by country_code in
--     the reporting queries only when zooming in is needed.
--
-- ⚠️ rider_kpi.batch_number data-quality finding (2026-07-15):
--   This field is populated ONLY on the specific day(s) each week when
--   Rooster's scoring run computes it for that country — it's an event
--   marker, NOT a stable daily attribute. Verified on AR and TW: daily
--   coverage swings from ~99% to 0% and back within the same week, and
--   WHICH days are "gap" days changes unpredictably week to week and
--   country to country (confirmed via day-of-week breakdown — this is not
--   simply "weekends are empty"). Naively picking "the last day of the
--   week" (the first version of this script) landed on gap days constantly
--   and produced a false ~83% "no batch" rate globally. Fix: forward-fill
--   the last known non-null value per rider across the full daily series
--   (Table 0A below) before collapsing to week or checking coverage. Do NOT
--   remove this forward-fill step or revert to a plain per-week/per-day
--   pick — it will silently reintroduce the bug.
--   Considered and rejected: MAX(batch_number) per week (simpler, no buffer
--   needed). Tested on the classification window: 23.55% of rider-weeks
--   have ZERO days with any batch value that week — MAX() would still show
--   "No batch" for those even though the rider almost certainly has a valid
--   batch carried from a prior week's scoring run. Also, 1.66% of rider-
--   weeks have >1 distinct batch value within the week (a real mid-week
--   change); MAX() picks the numerically higher (worse) one, not the most
--   recent. Forward-fill handles both correctly for one extra window-
--   function pass — keep it.
-- ============================================================================

DECLARE latest_week      DATE DEFAULT (SELECT MAX(week_start) FROM `logistics-data-storage-staging.Maripaz.threshold_tool_rider_weekly`);
DECLARE class_end        DATE DEFAULT DATE_SUB(latest_week, INTERVAL 12 WEEK);  -- classification cutoff — leaves 12 observed weeks for retention
DECLARE class_start      DATE DEFAULT DATE_SUB(class_end, INTERVAL 13 WEEK);    -- 13-week (~3 month) long-term window: [class_start, class_end)
DECLARE retain_4wk       DATE DEFAULT DATE_ADD(class_end, INTERVAL 4 WEEK);
DECLARE retain_12wk      DATE DEFAULT DATE_ADD(class_end, INTERVAL 12 WEEK);
DECLARE rk_latest_day    DATE DEFAULT (SELECT MAX(created_date_local) FROM `fulfillment-dwh-production.cl.rider_kpi`);
DECLARE coverage_start   DATE DEFAULT DATE_SUB(rk_latest_day, INTERVAL 12 WEEK); -- separate "last 12 weeks" window for the no-batch coverage check
DECLARE batch_fill_start DATE DEFAULT DATE_SUB(class_start, INTERVAL 8 WEEK);    -- buffer before the window so the forward-fill has a seed value

-- ============================================================================
-- TABLE 0A: Forward-filled daily batch per rider, from rider_kpi.batch_number.
-- See the data-quality warning above — this step is required, not optional.
-- Covers batch_fill_start..rk_latest_day (a superset of both the coverage
-- check window and the classification window) so it can feed both Table 0
-- and Table 0B without re-scanning rider_kpi twice.
-- This is the most expensive table in the script (full rider_kpi daily scan
-- across ~33 weeks, all countries) — expect it to dominate run cost/time.
-- ============================================================================
CREATE OR REPLACE TABLE `logistics-data-storage-staging.Maripaz.m2_rider_daily_batch_filled`
PARTITION BY created_date_local
CLUSTER BY country_code, rider_id
AS
WITH daily_raw AS (
  SELECT
    created_date_local,
    country_code,
    rider_id,
    ANY_VALUE(batch_number) AS batch_number  -- constant per rider-day across any zone/entity splits in rider_kpi
  FROM `fulfillment-dwh-production.cl.rider_kpi`
  WHERE created_date_local >= batch_fill_start
    AND created_date_local <= rk_latest_day
    AND country_code != 'de2'
  GROUP BY 1, 2, 3
)
SELECT
  created_date_local,
  country_code,
  rider_id,
  LAST_VALUE(batch_number IGNORE NULLS) OVER (
    PARTITION BY country_code, rider_id
    ORDER BY created_date_local
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS batch_number_filled
FROM daily_raw;

-- ============================================================================
-- TABLE 0: Countries to exclude from the whole analysis. Three reasons:
--   (a) AUTO — >90% of riders active in the last 12 weeks show no batch
--       (forward-filled). 2026-07-15 result: t5. (gv-it also trips this but
--       is covered by (c).)
--   (b) MANUAL — team-confirmed not live with Scoring (at, ph). These show
--       LOW no-batch rates so the auto check would NOT catch them.
--   (c) GLOVO — all gv-* markets. Excluded 2026-07-16: Glovo runs a ~16-batch
--       near-uniform scoring system, so "B1-B2" is not comparable to the ~4-6
--       batch systems elsewhere; pooling inflated the non-top-batch headline
--       48%->52%. Analyze Glovo separately with its own batch bucketing.
-- To add non-Glovo manual exclusions later, extend the `manual` array; Glovo
-- is handled by the pattern branch so new gv-* markets are auto-covered.
-- ============================================================================
CREATE OR REPLACE TABLE `logistics-data-storage-staging.Maripaz.m2_excluded_countries`
AS
WITH rider_last_batch AS (
  SELECT
    country_code,
    rider_id,
    ARRAY_AGG(batch_number_filled ORDER BY created_date_local DESC LIMIT 1)[OFFSET(0)] AS last_batch_number
  FROM `logistics-data-storage-staging.Maripaz.m2_rider_daily_batch_filled`
  WHERE created_date_local >= coverage_start
    AND created_date_local <= rk_latest_day
  GROUP BY 1, 2
),
auto_excluded AS (
  SELECT
    country_code,
    'auto: >90% no batch (last 12 weeks)' AS reason,
    COUNT(*)                                                          AS riders,
    COUNTIF(last_batch_number IS NULL)                                AS riders_no_batch,
    ROUND(SAFE_DIVIDE(COUNTIF(last_batch_number IS NULL), COUNT(*)) * 100, 1) AS pct_no_batch
  FROM rider_last_batch
  GROUP BY 1
  HAVING pct_no_batch > 90 AND country_code NOT LIKE 'gv-%'   -- gv-* handled by (c)
),
manual_excluded AS (
  SELECT country_code, 'manual: not live with Scoring per team (2026-07-16)' AS reason, NULL AS riders, NULL AS riders_no_batch, NULL AS pct_no_batch
  FROM UNNEST(['at', 'ph']) AS country_code
),
glovo_excluded AS (
  SELECT DISTINCT country_code, 'glovo: non-comparable ~16-batch system (2026-07-16)' AS reason,
    NULL AS riders, NULL AS riders_no_batch, NULL AS pct_no_batch
  FROM `logistics-data-storage-staging.Maripaz.m2_rider_daily_batch_filled`
  WHERE country_code LIKE 'gv-%'
)
SELECT * FROM auto_excluded
UNION ALL SELECT * FROM manual_excluded
UNION ALL SELECT * FROM glovo_excluded;

-- ============================================================================
-- TABLE 0B: Rider-week batch, collapsed from the forward-filled daily table
-- (Table 0A) via the last day observed in each week. Scoped to the
-- classification window and excludes Table 0's countries.
-- ============================================================================
CREATE OR REPLACE TABLE `logistics-data-storage-staging.Maripaz.m2_rider_weekly_batch`
PARTITION BY week_start
CLUSTER BY country_code, rider_id
AS
SELECT
  DATE_TRUNC(created_date_local, WEEK(MONDAY))                                  AS week_start,
  country_code,
  rider_id,
  ARRAY_AGG(batch_number_filled ORDER BY created_date_local DESC LIMIT 1)[OFFSET(0)] AS batch_number
FROM `logistics-data-storage-staging.Maripaz.m2_rider_daily_batch_filled`
WHERE created_date_local >= class_start
  AND created_date_local <  class_end
  AND country_code NOT IN (SELECT country_code FROM `logistics-data-storage-staging.Maripaz.m2_excluded_countries`)
GROUP BY 1, 2, 3;

-- ============================================================================
-- TABLE 1: Exact delivery-grain special-hours rebuild, rider-week grain.
-- Mirrors threshold_tool_rider_weekly.sql STEP 5 (shift x special-hours
-- window intersection), but applied to individual delivery drop-off
-- timestamps instead of shift intervals, per the "exact rebuild" decision.
-- ============================================================================
CREATE OR REPLACE TABLE `logistics-data-storage-staging.Maripaz.m2_special_hours_deliveries_week`
PARTITION BY week_start
CLUSTER BY country_code, city_id, rider_id
AS
WITH
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

completed_deliveries AS (
  SELECT
    o.country_code,
    d.city_id,
    d.rider_id,
    DATE(d.rider_dropped_off_at, d.timezone)     AS delivery_date_local,
    DATETIME(d.rider_dropped_off_at, d.timezone) AS dropped_off_local
  FROM `fulfillment-dwh-production.cl.orders` o, UNNEST(o.deliveries) AS d
  WHERE o.created_date        >= DATE_SUB(class_start, INTERVAL 7 DAY)  -- buffer: orders created just before the window that complete inside it
    AND o.created_date        <  class_end
    AND d.delivery_status      = 'completed'
    AND d.is_primary           = TRUE
    AND d.rider_id             IS NOT NULL
    AND d.rider_dropped_off_at IS NOT NULL
    AND o.country_code         != 'de2'
    AND o.country_code         NOT IN (SELECT country_code FROM `logistics-data-storage-staging.Maripaz.m2_excluded_countries`)
),

-- day_of_week mapping (same convention as threshold_tool_rider_weekly.sql):
--   BQ EXTRACT(DAYOFWEEK): 1=Sun, 2=Mon, … 7=Sat
--   scoring_settings:      0=Mon, 1=Tue, … 6=Sun  -> MOD(DAYOFWEEK + 5, 7)
-- Known limitation (inherited from the shifts version): overnight windows
-- are not specially handled; a delivery just after midnight is evaluated
-- against its own calendar date's window only.
delivery_special_hours_flag AS (
  SELECT
    cd.country_code,
    cd.city_id,
    cd.rider_id,
    cd.delivery_date_local,
    EXISTS (
      SELECT 1 FROM special_hours_config shc
      WHERE shc.country_code = cd.country_code
        AND shc.city_id      = cd.city_id
        AND shc.day_of_week  = MOD(EXTRACT(DAYOFWEEK FROM cd.delivery_date_local) + 5, 7)
        AND cd.dropped_off_local BETWEEN DATETIME(cd.delivery_date_local, shc.from_hour)
                                      AND DATETIME(cd.delivery_date_local, shc.to_hour)
    ) AS is_special_hours_delivery
  FROM completed_deliveries cd
)

SELECT
  DATE_TRUNC(delivery_date_local, WEEK(MONDAY)) AS week_start,
  country_code,
  city_id,
  rider_id,
  COUNT(*)                           AS deliveries_total_rebuild,
  COUNTIF(is_special_hours_delivery) AS deliveries_special_hours
FROM delivery_special_hours_flag
WHERE delivery_date_local >= class_start
  AND delivery_date_local <  class_end
GROUP BY 1, 2, 3, 4;

-- ============================================================================
-- TABLE 2: Rider-grain long-term segments — the primary matrix table.
-- One row per rider: window deliveries, percentile groups (per country),
-- last observed batch, tenure since first delivery, 4wk/12wk retention.
-- ============================================================================
CREATE OR REPLACE TABLE `logistics-data-storage-staging.Maripaz.m2_rider_segments`
CLUSTER BY country_code, group_weighted
AS
WITH
rider_weekly_window AS (
  SELECT
    t.week_start,
    t.country_code,
    t.city_id,
    t.city_name,
    t.brand,
    t.rider_id,
    t.deliveries,
    IFNULL(CAST(wb.batch_number AS STRING), 'No batch') AS batch,
    IFNULL(sh.deliveries_special_hours, 0)              AS deliveries_special_hours
  FROM `logistics-data-storage-staging.Maripaz.threshold_tool_rider_weekly` t
  LEFT JOIN `logistics-data-storage-staging.Maripaz.m2_rider_weekly_batch` wb
    ON  wb.week_start   = t.week_start
    AND wb.country_code = t.country_code
    AND wb.rider_id      = t.rider_id
  LEFT JOIN `logistics-data-storage-staging.Maripaz.m2_special_hours_deliveries_week` sh
    ON  t.week_start   = sh.week_start
    AND t.country_code = sh.country_code
    AND t.city_id       = sh.city_id
    AND t.rider_id      = sh.rider_id
  WHERE t.week_start >= class_start
    AND t.week_start <  class_end
    AND t.country_code NOT IN (SELECT country_code FROM `logistics-data-storage-staging.Maripaz.m2_excluded_countries`)
),

-- Riders with zero deliveries across the full 13-week window never appear
-- in threshold_tool_rider_weekly and are therefore excluded here entirely
-- (not forced into the bottom group) — they're effectively already churned
-- and are better captured by the retention metric than by segment membership.
rider_window_totals AS (
  SELECT
    rider_id,
    country_code,
    ARRAY_AGG(city_id   ORDER BY week_start DESC LIMIT 1)[OFFSET(0)] AS city_id,
    ARRAY_AGG(city_name ORDER BY week_start DESC LIMIT 1)[OFFSET(0)] AS city_name,
    ARRAY_AGG(brand      ORDER BY week_start DESC LIMIT 1)[OFFSET(0)] AS brand,
    ARRAY_AGG(batch       ORDER BY week_start DESC LIMIT 1)[OFFSET(0)] AS last_batch,
    SUM(deliveries)                                                    AS window_deliveries,
    SUM(deliveries_special_hours)                                      AS window_deliveries_special_hours,
    COUNT(DISTINCT week_start)                                         AS active_weeks_in_window
  FROM rider_weekly_window
  GROUP BY rider_id, country_code
),

rider_segments AS (
  SELECT
    *,
    PERCENT_RANK() OVER (PARTITION BY country_code ORDER BY window_deliveries) AS deliveries_pct_rank,
    NTILE(4) OVER (PARTITION BY country_code ORDER BY window_deliveries)        AS group_equal_ntile,
    NTILE(2) OVER (PARTITION BY country_code ORDER BY window_deliveries)        AS group_2_ntile
  FROM rider_window_totals
),

rider_segments_labeled AS (
  SELECT
    *,
    -- Weighted 4-group split: G1 top 10%, G2 next 20%, G3 next 30%, G4 bottom 40%
    CASE
      WHEN deliveries_pct_rank >= 0.90 THEN 'G1 (Top 10%)'
      WHEN deliveries_pct_rank >= 0.70 THEN 'G2 (P70-89)'
      WHEN deliveries_pct_rank >= 0.40 THEN 'G3 (P40-69)'
      ELSE                                   'G4 (Below P40)'
    END AS group_weighted,
    -- Equal-quartile alternative, kept alongside for comparison
    CASE group_equal_ntile
      WHEN 4 THEN 'Q1 (Top 25%)'
      WHEN 3 THEN 'Q2 (P50-74)'
      WHEN 2 THEN 'Q3 (P25-49)'
      WHEN 1 THEN 'Q4 (Bottom 25%)'
    END AS group_equal,
    -- 2-group median split
    CASE group_2_ntile
      WHEN 2 THEN 'H1 (Top 50%)'
      WHEN 1 THEN 'H2 (Bottom 50%)'
    END AS group_2
  FROM rider_segments
),

-- Tenure source: first-ever COMPLETED delivery, not account creation date.
-- Bounded to 4 years back for cost control (full orders scan otherwise).
rider_first_delivery AS (
  SELECT
    o.country_code,
    d.rider_id,
    MIN(DATE(d.rider_dropped_off_at, d.timezone)) AS first_delivery_date
  FROM `fulfillment-dwh-production.cl.orders` o, UNNEST(o.deliveries) AS d
  WHERE o.created_date        >= DATE_SUB(class_end, INTERVAL 4 YEAR)
    AND o.created_date        <  class_end
    AND d.delivery_status      = 'completed'
    AND d.is_primary           = TRUE
    AND d.rider_id             IS NOT NULL
    AND d.rider_dropped_off_at IS NOT NULL
    AND o.country_code         != 'de2'
    AND o.country_code         NOT IN (SELECT country_code FROM `logistics-data-storage-staging.Maripaz.m2_excluded_countries`)
  GROUP BY 1, 2
),

retention_4wk AS (
  SELECT DISTINCT rider_id, country_code
  FROM `logistics-data-storage-staging.Maripaz.threshold_tool_rider_weekly`
  WHERE week_start = retain_4wk
),

retention_12wk AS (
  SELECT DISTINCT rider_id, country_code
  FROM `logistics-data-storage-staging.Maripaz.threshold_tool_rider_weekly`
  WHERE week_start = retain_12wk
)

SELECT
  rs.rider_id,
  rs.country_code,
  rs.city_id,
  rs.city_name,
  rs.brand,
  rs.window_deliveries,
  rs.window_deliveries_special_hours,
  ROUND(SAFE_DIVIDE(rs.window_deliveries_special_hours, NULLIF(rs.window_deliveries, 0)), 4) AS pct_deliveries_special_hours,
  rs.active_weeks_in_window,
  rs.last_batch,
  rs.group_weighted,
  rs.group_equal,
  rs.group_2,
  fd.first_delivery_date,
  DATE_DIFF(class_end, fd.first_delivery_date, WEEK)                  AS tenure_weeks,
  (fd.first_delivery_date <= DATE_SUB(class_end, INTERVAL 4 YEAR))    AS tenure_left_censored,
  (r4.rider_id  IS NOT NULL)                                          AS retained_4wk,
  (r12.rider_id IS NOT NULL)                                          AS retained_12wk,
  class_start AS window_start,
  class_end   AS window_end
FROM rider_segments_labeled rs
LEFT JOIN rider_first_delivery fd
  ON fd.rider_id = rs.rider_id AND fd.country_code = rs.country_code
LEFT JOIN retention_4wk r4
  ON r4.rider_id = rs.rider_id AND r4.country_code = rs.country_code
LEFT JOIN retention_12wk r12
  ON r12.rider_id = rs.rider_id AND r12.country_code = rs.country_code;

-- ============================================================================
-- TABLE 3: Rider-week grain — batch history within a fixed long-term group.
-- Use this if "last batch" (Table 2) looks too noisy to represent a group;
-- it gives the full distribution of batches a group's riders passed through
-- during the window (i.e. rider-WEEK counts per group x batch, not just a
-- snapshot).
-- ============================================================================
CREATE OR REPLACE TABLE `logistics-data-storage-staging.Maripaz.m2_rider_week_batches`
PARTITION BY week_start
CLUSTER BY country_code, group_weighted
AS
SELECT
  t.week_start,
  t.country_code,
  t.city_id,
  t.brand,
  t.rider_id,
  IFNULL(CAST(wb.batch_number AS STRING), 'No batch') AS week_batch,
  t.deliveries                                        AS week_deliveries,
  IFNULL(sh.deliveries_special_hours, 0)              AS week_deliveries_special_hours,
  s.group_weighted,
  s.group_equal,
  s.group_2
FROM `logistics-data-storage-staging.Maripaz.threshold_tool_rider_weekly` t
JOIN `logistics-data-storage-staging.Maripaz.m2_rider_segments` s
  ON  s.rider_id     = t.rider_id
  AND s.country_code = t.country_code
LEFT JOIN `logistics-data-storage-staging.Maripaz.m2_rider_weekly_batch` wb
  ON  wb.week_start   = t.week_start
  AND wb.country_code = t.country_code
  AND wb.rider_id      = t.rider_id
LEFT JOIN `logistics-data-storage-staging.Maripaz.m2_special_hours_deliveries_week` sh
  ON  t.week_start   = sh.week_start
  AND t.country_code = sh.country_code
  AND t.city_id       = sh.city_id
  AND t.rider_id      = sh.rider_id
WHERE t.week_start >= s.window_start
  AND t.week_start <  s.window_end;

-- ============================================================================
-- REPORTING QUERIES — run after the tables above are built.
-- All enforce the 50-rider minimum cell size. Swap `group_weighted` for
-- `group_equal` or `group_2` to compare the alternative groupings; add
-- `WHERE country_code = 'xx'` to zoom into a specific country.
-- ============================================================================

-- (1) % of riders per Segment x Last-Batch cell
WITH cell_counts AS (
  SELECT group_weighted, last_batch, COUNT(*) AS riders
  FROM `logistics-data-storage-staging.Maripaz.m2_rider_segments`
  GROUP BY 1, 2
)
SELECT
  group_weighted,
  last_batch,
  riders,
  ROUND(SAFE_DIVIDE(riders, SUM(riders) OVER ()) * 100, 2) AS pct_of_riders
FROM cell_counts
WHERE riders >= 50
ORDER BY group_weighted, last_batch;

-- (2) % of deliveries per cell
SELECT
  group_weighted,
  last_batch,
  COUNT(*)               AS riders,
  SUM(window_deliveries) AS deliveries,
  ROUND(SAFE_DIVIDE(SUM(window_deliveries), SUM(SUM(window_deliveries)) OVER ()) * 100, 2) AS pct_of_deliveries
FROM `logistics-data-storage-staging.Maripaz.m2_rider_segments`
GROUP BY 1, 2
HAVING COUNT(*) >= 50
ORDER BY group_weighted, last_batch;

-- (3) % of deliveries made in special hours per cell
SELECT
  group_weighted,
  last_batch,
  COUNT(*)                             AS riders,
  SUM(window_deliveries)               AS deliveries,
  SUM(window_deliveries_special_hours) AS deliveries_special_hours,
  ROUND(SAFE_DIVIDE(SUM(window_deliveries_special_hours), SUM(window_deliveries)) * 100, 2) AS pct_deliveries_special_hours
FROM `logistics-data-storage-staging.Maripaz.m2_rider_segments`
GROUP BY 1, 2
HAVING COUNT(*) >= 50
ORDER BY group_weighted, last_batch;

-- (4) Retention (4wk / 12wk) per group (group-level, not crossed with batch)
SELECT
  group_weighted,
  COUNT(*)                                          AS riders,
  ROUND(AVG(CAST(retained_4wk  AS INT64)) * 100, 1) AS pct_retained_4wk,
  ROUND(AVG(CAST(retained_12wk AS INT64)) * 100, 1) AS pct_retained_12wk
FROM `logistics-data-storage-staging.Maripaz.m2_rider_segments`
GROUP BY 1
HAVING COUNT(*) >= 50
ORDER BY group_weighted;

-- (5) Average tenure per group
SELECT
  group_weighted,
  COUNT(*)                      AS riders,
  ROUND(AVG(tenure_weeks), 1)   AS avg_tenure_weeks,
  COUNTIF(tenure_left_censored) AS riders_left_censored
FROM `logistics-data-storage-staging.Maripaz.m2_rider_segments`
GROUP BY 1
HAVING COUNT(*) >= 50
ORDER BY group_weighted;

-- (6) Rider-WEEK count distribution per Segment x Batch (fallback view if
-- "last batch" in query 1 looks unrepresentative — see Table 3 comment)
WITH cell AS (
  SELECT group_weighted, week_batch, COUNT(*) AS rider_weeks
  FROM `logistics-data-storage-staging.Maripaz.m2_rider_week_batches`
  GROUP BY 1, 2
)
SELECT
  group_weighted,
  week_batch,
  rider_weeks,
  ROUND(SAFE_DIVIDE(rider_weeks, SUM(rider_weeks) OVER (PARTITION BY group_weighted)) * 100, 1) AS pct_of_group_weeks
FROM cell
WHERE rider_weeks >= 50
ORDER BY group_weighted, week_batch;

-- (7) Actual delivery-count cut values at P90/P70/P40 — per country and global.
-- Answers "what does the percentile boundary actually mean in deliveries" —
-- these vary a lot by country (e.g. a P40 cut of 20 deliveries in one
-- country vs. 950+ in another), which is why percentiles are computed per
-- country rather than pooled.
SELECT
  country_code,
  COUNT(*)                                             AS riders,
  APPROX_QUANTILES(window_deliveries, 100)[OFFSET(90)] AS p90_cut_deliveries,
  APPROX_QUANTILES(window_deliveries, 100)[OFFSET(70)] AS p70_cut_deliveries,
  APPROX_QUANTILES(window_deliveries, 100)[OFFSET(40)] AS p40_cut_deliveries
FROM `logistics-data-storage-staging.Maripaz.m2_rider_segments`
GROUP BY 1
HAVING COUNT(*) >= 50
ORDER BY riders DESC;

-- Global pooled reference (not used for segmentation itself — segmentation
-- is per-country — but useful for a single intuitive number)
SELECT
  COUNT(*)                                             AS riders,
  APPROX_QUANTILES(window_deliveries, 100)[OFFSET(90)] AS p90_cut_deliveries_global,
  APPROX_QUANTILES(window_deliveries, 100)[OFFSET(70)] AS p70_cut_deliveries_global,
  APPROX_QUANTILES(window_deliveries, 100)[OFFSET(40)] AS p40_cut_deliveries_global
FROM `logistics-data-storage-staging.Maripaz.m2_rider_segments`;
