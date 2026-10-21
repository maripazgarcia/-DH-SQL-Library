/*====================================================================
  TABLE: Canary + look-alike city manifest — source of truth
====================================================================
  PURPOSE:
    Single authoritative list of which cities are Milestone 1 canaries,
    which look-alike (control) city each is paired with, when each
    canary rolls out, and the target batch-size distribution each
    canary is calibrated against.

  CONSUMED BY:
    - bq_table_canary_kr_tracking.sql   (replaces its inline `manifest` CTE)
    - m1-statistical-impact-dashboard   (config.py PAIRS)
    - loyalty-batch-dashboard           (config.py CANARY_CITIES)

  RUNNING THIS FILE:
    CREATE OR REPLACE rebuilds the table from scratch every time, so this
    file is the only place the manifest is edited. Change a date or a
    target here, re-run, and both dashboards pick it up on their next
    weekly refresh. Safe to re-run — no incremental state.

  BATCH TARGETS:
    batch_targets holds the target % of non-newbie active riders per
    batch for each canary. Look-alike cities never launch Milestone 1,
    so their array is empty.

    These percentages do NOT come from any BigQuery table —
    `cl._scoring_settings` is confirmed stale. They are the output of
    Maripaz's M1 Threshold Recommendation tool (threshold_suggestion.ipynb)
    and must be updated by hand whenever she re-runs it.

      PH  (Bulacan, Batangas, Los Banos)  5 / 9 / 21 / 65
      SA  (Jazan, Al Ahsa, Al-Kharj)     10 / 20 / 30 / 40
      GV-UG (Kampala)                     5 / 5 / 20 / 30 / 40

  ROLLOUT DATES:
    rollout_date may sit in the future for a canary that hasn't launched
    yet (PH Bulacan / Batangas are 2026-10-28). Consumers should filter
    to `rollout_date <= CURRENT_DATE()` when they only want live cities.

  CREATED: 2026-10-02
====================================================================*/

CREATE OR REPLACE TABLE `logistics-data-storage-staging.Maripaz.canary_lookalike_manifest` (
  country_code   STRING,
  city_id        INT64,
  city_name      STRING,
  city_type      STRING,
  rollout_date   DATE,
  paired_canary  STRING,
  batch_targets  ARRAY<STRUCT<batch INT64, target_pct FLOAT64>>
);

INSERT INTO `logistics-data-storage-staging.Maripaz.canary_lookalike_manifest`
  (country_code, city_id, city_name, city_type, rollout_date, paired_canary, batch_targets)
VALUES
  -- PH — Bulacan / Batangas roll out 2026-10-28 (not yet live as of 2026-10-02)
  ('ph',    220, 'Bulacan',       'Canary',     DATE '2026-10-28', 'Bulacan',
     [STRUCT(1, 5.0), STRUCT(2, 9.0), STRUCT(3, 21.0), STRUCT(4, 65.0)]),
  ('ph',    203, 'Pampanga',      'Look-alike', DATE '2026-10-28', 'Bulacan',   []),
  ('ph',    204, 'Batangas',      'Canary',     DATE '2026-10-28', 'Batangas',
     [STRUCT(1, 5.0), STRUCT(2, 9.0), STRUCT(3, 21.0), STRUCT(4, 65.0)]),
  ('ph',    206, 'Bacolod',       'Look-alike', DATE '2026-10-28', 'Batangas',  []),
  ('ph',    252, 'Los Banos',     'Canary',     DATE '2026-09-21', 'Los Banos',
     [STRUCT(1, 5.0), STRUCT(2, 9.0), STRUCT(3, 21.0), STRUCT(4, 65.0)]),
  ('ph',    259, 'Tanza',         'Look-alike', DATE '2026-09-21', 'Los Banos', []),

  -- SA
  ('sa',    209, 'Jazan',         'Canary',     DATE '2026-08-03', 'Jazan',
     [STRUCT(1, 10.0), STRUCT(2, 20.0), STRUCT(3, 30.0), STRUCT(4, 40.0)]),
  ('sa',    207, 'Hafar al Batin','Look-alike', DATE '2026-08-03', 'Jazan',     []),
  ('sa',      7, 'Al Ahsa',       'Canary',     DATE '2026-09-21', 'Al Ahsa',
     [STRUCT(1, 10.0), STRUCT(2, 20.0), STRUCT(3, 30.0), STRUCT(4, 40.0)]),
  ('sa',    202, 'Tabuk',         'Look-alike', DATE '2026-09-21', 'Al Ahsa',   []),
  ('sa',      3, 'Al-Kharj',      'Canary',     DATE '2026-09-21', 'Al-Kharj',
     [STRUCT(1, 10.0), STRUCT(2, 20.0), STRUCT(3, 30.0), STRUCT(4, 40.0)]),
  ('sa',      8, 'Jubail',        'Look-alike', DATE '2026-09-21', 'Al-Kharj',  []),

  -- GV-UG — 5 batches, cross-country look-alike in GV-CI
  ('gv-ug',   1, 'Kampala',       'Canary',     DATE '2026-08-03', 'Kampala',
     [STRUCT(1, 5.0), STRUCT(2, 5.0), STRUCT(3, 20.0), STRUCT(4, 30.0), STRUCT(5, 40.0)]),
  ('gv-ci',   5, 'Abidjan Nord',  'Look-alike', DATE '2026-08-03', 'Kampala',   []),

  -- OM / AE (Talabat) — rolling out 2026-11-02. Back in scope as of
  -- 2026-10-12; they were dropped on 2026-08-28 and are not in any dashboard
  -- config outside this manifest. City/look-alike pairings carried over from
  -- the June manifest (bq_table_canary_kr_tracking.sql).
  --
  -- TODO: batch_targets are empty — the M1 Threshold Recommendation tool
  -- hasn't been run for OM/AE yet. Until they're filled in, the Results
  -- Tracker renders these cities without the "vs. target" comparison; every
  -- other panel works. Fill the arrays in the same shape as SA above.
  ('om',    211, 'Jalan',         'Canary',     DATE '2026-11-02', 'Jalan',     []),
  ('om',    203, 'Sur',           'Look-alike', DATE '2026-11-02', 'Jalan',     []),
  ('ae',    202, 'Al Ain',        'Canary',     DATE '2026-11-02', 'Al Ain',    []),
  ('ae',    200, 'Sharjah',       'Look-alike', DATE '2026-11-02', 'Al Ain',    []),
  ('ae',    201, 'Ajman',         'Canary',     DATE '2026-11-02', 'Ajman',     []),
  ('ae',    203, 'RAK',           'Look-alike', DATE '2026-11-02', 'Ajman',     []);
