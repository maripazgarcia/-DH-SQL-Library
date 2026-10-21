-- Pre-launch (7d baseline) vs. all days since launch (inclusive), account creation rate per country.
-- Uses only account_creation_fail / account_creation_success: the sole events
-- confirmed present both before and after launch (account_creation_otp_* is
-- new instrumentation that starts exactly on each country's launch date --
-- see diagnostic query in project notes -- so it can't be used for a
-- pre-launch baseline).
-- Add/edit countries and launch dates in `launch_dates` below.

WITH launch_dates AS (
  SELECT 'bd' AS country_code, DATE '2026-10-19' AS launch_date UNION ALL
  SELECT 'kh', DATE '2026-10-19' UNION ALL
  SELECT 'la', DATE '2026-10-13'
),

raw AS (
  SELECT
    e.user_pseudo_id,
    LOWER((SELECT value.string_value FROM UNNEST(e.user_properties) WHERE key = 'country' LIMIT 1)) AS country_code,
    e.event_name,
    e.created_date
  FROM `fulfillment-dwh-production.dl.road_runner_events` e
  WHERE e.created_date BETWEEN '2026-09-01' AND CURRENT_DATE()
    AND e.user_pseudo_id IS NOT NULL
    AND e.event_name IN ('account_creation_fail', 'account_creation_success')
    AND LOWER((SELECT value.string_value FROM UNNEST(e.user_properties) WHERE key = 'country' LIMIT 1)) IN ('bd', 'kh', 'la')
),

tagged AS (
  SELECT
    r.*,
    l.launch_date,
    CASE
      WHEN r.created_date >= l.launch_date THEN '1_post_launch'
      WHEN r.created_date BETWEEN DATE_SUB(l.launch_date, INTERVAL 7 DAY) AND DATE_SUB(l.launch_date, INTERVAL 1 DAY) THEN '2_pre_launch_7d'
    END AS period
  FROM raw r
  JOIN launch_dates l USING (country_code)
),

rider_outcomes AS (
  SELECT
    country_code,
    period,
    user_pseudo_id,
    COUNTIF(event_name = 'account_creation_success') AS accounts_created
  FROM tagged
  WHERE period IS NOT NULL
  GROUP BY country_code, period, user_pseudo_id
)

SELECT
  UPPER(country_code) AS country,
  period,
  COUNT(*) AS reached,
  COUNTIF(accounts_created > 0) AS created,
  FORMAT('%.1f%%', IFNULL(SAFE_DIVIDE(COUNTIF(accounts_created > 0), COUNT(*)) * 100, 0)) AS account_creation_rate
FROM rider_outcomes
GROUP BY country, period
ORDER BY country, period;
