-- Weekly-scheduled query for the M1 Statistical Impact dashboard.
-- Materializes rider-weekly AR/AvP/Deliveries for every canary + look-alike
-- city currently in config.py's PAIRS, so the local render step
-- (src/fetch_data.py) can do a cheap SELECT against this table instead of
-- re-running the live daily-grain query against rider_kpi every time.
--
-- IMPORTANT: the (country_code, city_id) list below is hardcoded and must be
-- kept in sync by hand with config.PAIRS. Whenever a pair is added/removed
-- in config.py, update the VALUES list here too and re-save this query in
-- the BQ console's scheduled query (or re-run scripts/sync_scheduled_query.sh
-- if that gets built later). See README.md "Automation" section.
--
-- Cities as of 2026-09-21 (7 active pairs, 14 distinct cities):
--   sa/209 Jazan, sa/207 Hafar al Batin       (sa_jazan)
--   gv-ug/1 Kampala, gv-ci/5 Abidjan Nord     (gvug_kampala)
--   ph/220 Bulacan, ph/203 Pampanga           (ph_bulacan)
--   ph/204 Batangas, ph/206 Bacolod           (ph_batangas)
--   ph/252 Los Banos, ph/259 Tanza            (ph_los_banos)
--   sa/7 Al Ahsa, sa/202 Tabuk                (sa_al_ahsa)
--   sa/3 Al-Kharj, sa/8 Jubail                (sa_al_kharj)
--
-- om_jalan / ae_al_ain / ae_ajman are commented out below (2026-09-21) --
-- they're in the canary+look-alike manifest in Threshold Recommendation/
-- bq_table_canary_kr_tracking.sql, but those cities don't have a definitive
-- M1 launch date yet. Uncomment (and add to config.py's PAIRS) once a launch
-- date is confirmed. EC (Machala/Ibarra) is in that manifest too but stays
-- excluded here per the documented 2026-08-28 decision in config.py (fleets
-- too small to read out on AvP/Deliveries) -- not a launch-date issue, so
-- it's not listed below as a pending pair.

CREATE OR REPLACE TABLE `logistics-data-storage-staging.Maripaz.m1_statistical_impact_rider_weekly`
PARTITION BY week_start
CLUSTER BY country_code, city_id
OPTIONS (
  labels = [("owner", "maripaz"), ("theme", "loyalty_m1")],
  description = "Rider-weekly AR/AvP/Deliveries for the M1 Statistical Impact dashboard's canary + look-alike cities. Refreshed weekly by a BQ scheduled query; hardcoded city list must be kept in sync with m1-statistical-impact-dashboard/config.py."
) AS
WITH scoped_cities AS (
  -- pair_key/role identify which config.PAIRS entry each city belongs to and
  -- whether it's the canary (rolled out M1) or the look-alike (control, never
  -- launches) -- lets the render step tell them apart without re-deriving it
  -- from config.py at read time.
  SELECT * FROM UNNEST([
    STRUCT('sa' AS country_code, 209 AS city_id, 'sa_jazan' AS pair_key, 'canary' AS role),
    STRUCT('sa' AS country_code, 207 AS city_id, 'sa_jazan' AS pair_key, 'lookalike' AS role),
    STRUCT('gv-ug' AS country_code, 1 AS city_id, 'gvug_kampala' AS pair_key, 'canary' AS role),
    STRUCT('gv-ci' AS country_code, 5 AS city_id, 'gvug_kampala' AS pair_key, 'lookalike' AS role),
    STRUCT('ph' AS country_code, 220 AS city_id, 'ph_bulacan' AS pair_key, 'canary' AS role),
    STRUCT('ph' AS country_code, 203 AS city_id, 'ph_bulacan' AS pair_key, 'lookalike' AS role),
    STRUCT('ph' AS country_code, 204 AS city_id, 'ph_batangas' AS pair_key, 'canary' AS role),
    STRUCT('ph' AS country_code, 206 AS city_id, 'ph_batangas' AS pair_key, 'lookalike' AS role),
    STRUCT('ph' AS country_code, 252 AS city_id, 'ph_los_banos' AS pair_key, 'canary' AS role),
    STRUCT('ph' AS country_code, 259 AS city_id, 'ph_los_banos' AS pair_key, 'lookalike' AS role),
    STRUCT('sa' AS country_code, 7 AS city_id, 'sa_al_ahsa' AS pair_key, 'canary' AS role),
    STRUCT('sa' AS country_code, 202 AS city_id, 'sa_al_ahsa' AS pair_key, 'lookalike' AS role),
    STRUCT('sa' AS country_code, 3 AS city_id, 'sa_al_kharj' AS pair_key, 'canary' AS role),
    STRUCT('sa' AS country_code, 8 AS city_id, 'sa_al_kharj' AS pair_key, 'lookalike' AS role)
    -- Pending confirmed launch date -- uncomment (and add to config.py) once set:
    -- , STRUCT('om' AS country_code, 211 AS city_id, 'om_jalan' AS pair_key, 'canary' AS role)
    -- , STRUCT('om' AS country_code, 203 AS city_id, 'om_jalan' AS pair_key, 'lookalike' AS role)
    -- , STRUCT('ae' AS country_code, 202 AS city_id, 'ae_al_ain' AS pair_key, 'canary' AS role)
    -- , STRUCT('ae' AS country_code, 200 AS city_id, 'ae_al_ain' AS pair_key, 'lookalike' AS role)
    -- , STRUCT('ae' AS country_code, 201 AS city_id, 'ae_ajman' AS pair_key, 'canary' AS role)
    -- , STRUCT('ae' AS country_code, 203 AS city_id, 'ae_ajman' AS pair_key, 'lookalike' AS role)
  ])
),
weekly_ar AS (
  SELECT
    r.country_code,
    r.city_id,
    sc.pair_key,
    sc.role,
    DATE_TRUNC(r.created_date_local, WEEK(MONDAY)) AS week_start,
    r.rider_id,
    SAFE_DIVIDE(SUM(d.actual_rider_accepted) - SUM(d.manual_undispatched), NULLIF(SUM(d.actual_rider_notified), 0)) AS ar,
    SUM(d.actual_rider_accepted) AS deliveries
  FROM `fulfillment-dwh-production.cl.rider_kpi` r, UNNEST(r.deliveries) AS d
  JOIN scoped_cities sc USING (country_code, city_id)
  WHERE r.created_date_local >= DATE_SUB(CURRENT_DATE(), INTERVAL 24 WEEK)
    AND d.actual_rider_notified > 0
  GROUP BY 1, 2, 3, 4, 5, 6
),
weekly_avp AS (
  SELECT
    r.country_code,
    r.city_id,
    DATE_TRUNC(r.created_date_local, WEEK(MONDAY)) AS week_start,
    r.rider_id,
    SAFE_DIVIDE(SUM(r.working_time), NULLIF(SUM(r.planned_working_time), 0)) AS avp
  FROM `fulfillment-dwh-production.cl.rider_kpi` r
  JOIN scoped_cities sc USING (country_code, city_id)
  WHERE r.created_date_local >= DATE_SUB(CURRENT_DATE(), INTERVAL 24 WEEK)
    AND r.planned_working_time > 0
  GROUP BY 1, 2, 3, 4
)
SELECT
  ar.country_code, ar.city_id, ar.pair_key, ar.role, ar.week_start, ar.rider_id,
  ar.ar, ar.deliveries, avp.avp
FROM weekly_ar ar
JOIN weekly_avp avp USING (country_code, city_id, week_start, rider_id)
WHERE ar.ar IS NOT NULL AND avp.avp IS NOT NULL
