-- OTP success rate scorecard for rider account creation, by country/platform.
-- Edit `params.window_start/window_end/countries` to rerun for a different window or market.
CREATE TEMP FUNCTION EXTRACT_EVENT_PARAMS(_key STRING, _properties ANY TYPE) AS (
  (SELECT value.string_value FROM UNNEST(_properties) WHERE key = _key LIMIT 1)
);

WITH params AS (
  SELECT
    TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY)) AS window_start,  -- yesterday 00:00 UTC
    CURRENT_TIMESTAMP() AS window_end,
    ['la'] AS countries  -- e.g. ['la', 'iq']; use CAST([] AS ARRAY<STRING>) for all countries
),

raw AS (
  SELECT
    e.user_pseudo_id,
    e.device.operating_system AS platform,
    LOWER(EXTRACT_EVENT_PARAMS('country', e.user_properties)) AS country_code,
    e.event_name,
    TIMESTAMP_MICROS(e.event_timestamp) AS event_time,
    EXTRACT_EVENT_PARAMS('status', e.event_params) AS status,
    EXTRACT_EVENT_PARAMS('method', e.event_params) AS otp_entry_method,
    EXTRACT_EVENT_PARAMS('errorCode', e.event_params) AS error_code,
    EXTRACT_EVENT_PARAMS('errorMsg', e.event_params) AS error_message,
    EXTRACT_EVENT_PARAMS('reason', e.event_params) AS max_attempts_reason
  FROM `fulfillment-dwh-production.dl.road_runner_events` e, params p
  WHERE e.created_date BETWEEN DATE_SUB(DATE(p.window_start), INTERVAL 1 DAY) AND DATE_ADD(DATE(p.window_end), INTERVAL 1 DAY)
    AND TIMESTAMP_MICROS(e.event_timestamp) >= p.window_start
    AND TIMESTAMP_MICROS(e.event_timestamp) < p.window_end
    AND e.user_pseudo_id IS NOT NULL
    AND (
      e.event_name LIKE 'account_creation_otp%'
      OR e.event_name IN ('reset_password_request_again_clicked', 'otp_verify_success', 'otp_verify_fail', 'account_creation_success')
    )
),

reset_markers AS (
  SELECT user_pseudo_id, event_time
  FROM raw
  WHERE event_name IN ('reset_password_request_again_clicked', 'otp_verify_success', 'otp_verify_fail')
),

-- iOS reset password fires a twin event within milliseconds; a submit is followed by otp_verify_* once the API answers
account_creation_otp AS (
  SELECT r.*
  FROM raw r
  CROSS JOIN params p
  LEFT JOIN reset_markers m
    ON m.user_pseudo_id = r.user_pseudo_id
   AND m.event_time BETWEEN TIMESTAMP_SUB(r.event_time, INTERVAL 1 SECOND)
                        AND TIMESTAMP_ADD(r.event_time, INTERVAL IF(r.event_name = 'account_creation_otp_code_submit', 30, 1) SECOND)
  WHERE r.event_name LIKE 'account_creation_otp%'
    AND m.user_pseudo_id IS NULL
    AND (ARRAY_LENGTH(p.countries) = 0 OR r.country_code IN UNNEST(p.countries))
),

otp_events AS (
  SELECT * FROM account_creation_otp
  UNION ALL
  SELECT * FROM raw
  WHERE event_name = 'account_creation_success'
    AND user_pseudo_id IN (SELECT user_pseudo_id FROM account_creation_otp)
),

rider_outcomes AS (
  SELECT
    *,
    CASE
      WHEN accounts_created > 0 THEN '1_account_created'
      WHEN verified > 0 THEN '2_verified_but_no_account'
      WHEN lockouts > 0 THEN '3_locked_out'
      WHEN submits > 0 THEN '4_submitted_never_verified'
      WHEN request_fails > 0 THEN '5_code_request_failed'
      WHEN resends > 0 THEN '6_resent_never_submitted'
      ELSE '7_other'
    END AS outcome
  FROM (
    SELECT
      platform,
      user_pseudo_id,
      ANY_VALUE(country_code) AS country_code,
      MIN(event_time) AS first_seen,
      COUNTIF(event_name = 'account_creation_otp_resend_clicked') AS resends,
      COUNTIF(event_name = 'account_creation_otp_code_submit') AS submits,
      COUNTIF(event_name = 'account_creation_otp_code_submit' AND otp_entry_method = 'autofill') AS autofill_submits,
      COUNTIF(event_name = 'account_creation_otp_verification' AND status = 'success') AS verified,
      COUNTIF(event_name = 'account_creation_otp_verification' AND status IN ('failure', 'failed')) AS failed_verifications,
      COUNTIF(event_name = 'account_creation_otp_request_fail') AS request_fails,
      COUNTIF(event_name = 'account_creation_otp_max_attempts_reached') AS lockouts,
      COUNTIF(event_name = 'account_creation_success') AS accounts_created
    FROM otp_events
    GROUP BY platform, user_pseudo_id
  )
)

-- Scorecard, one row per metric
, scorecard AS (
  SELECT
    platform,
    country_code,
    COUNT(*) AS reached,
    COUNTIF(submits > 0) AS submitted,
    COUNTIF(verified > 0) AS verified,
    COUNTIF(accounts_created > 0) AS created,
    COUNTIF(resends > 0 AND submits = 0) AS resent_only,
    COUNTIF(lockouts > 0) AS locked_out,
    SUM(submits) AS total_submits,
    SUM(verified) AS total_verified,
    SUM(autofill_submits) AS total_autofill,
    AVG(resends) AS avg_resends
  FROM rider_outcomes
  GROUP BY platform, country_code
)

SELECT
  UPPER(s.country_code) AS `Country`,
  s.platform AS `Platform`,
  m.metric AS `Metric`,
  m.value AS `Value`,
  m.meaning AS `What it means`
FROM scorecard s,
UNNEST([
  STRUCT(1 AS step, 'Riders who reached the OTP screen' AS metric, CAST(s.reached AS STRING) AS value, 'Riders who did anything on the account creation OTP screen' AS meaning),
  STRUCT(2, 'Riders who entered a code', CAST(s.submitted AS STRING), 'Typed or autofilled a code at least once'),
  STRUCT(3, 'Riders whose code was accepted', CAST(s.verified AS STRING), 'Passed OTP verification'),
  STRUCT(4, 'Riders who created an account', CAST(s.created AS STRING), 'Finished account creation after OTP'),
  STRUCT(5, 'OTP success rate', FORMAT('%.1f%%', IFNULL(SAFE_DIVIDE(s.verified, s.reached) * 100, 0)), 'Reached the screen → code accepted. The headline number'),
  STRUCT(6, 'Account creation rate', FORMAT('%.1f%%', IFNULL(SAFE_DIVIDE(s.created, s.reached) * 100, 0)), 'Reached the screen → account created'),
  STRUCT(7, 'Codes accepted', FORMAT('%.1f%%', IFNULL(SAFE_DIVIDE(s.total_verified, s.total_submits) * 100, 0)), 'Share of all entered codes the backend accepted. Low = wrong codes or API errors'),
  STRUCT(8, 'Gave up waiting for SMS', FORMAT('%.1f%%', IFNULL(SAFE_DIVIDE(s.resent_only, s.reached) * 100, 0)), 'Tapped resend but never entered a code. High = SMS not arriving'),
  STRUCT(9, 'Locked out', FORMAT('%.1f%%', IFNULL(SAFE_DIVIDE(s.locked_out, s.reached) * 100, 0)), 'Hit the max attempts limit (new iOS tracking only)'),
  STRUCT(10, 'Resends per rider', FORMAT('%.1f', s.avg_resends), 'Average resend taps. Above ~1 = SMS slow or missing'),
  STRUCT(11, 'Autofilled codes', FORMAT('%.1f%%', IFNULL(SAFE_DIVIDE(s.total_autofill, s.total_submits) * 100, 0)), 'Share of codes filled from the SMS automatically')
]) m
ORDER BY `Country`, `Platform`, m.step;
