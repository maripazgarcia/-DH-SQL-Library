-- City-level recruitment KPIs for the 12 most undersupplied cities (underhired)
-- Scope: 2026-01-01 to present
-- Metrics: hired riders, activation (1st order), adoption (100 orders), RAF/NHB/ELF enrollment

WITH city_lookup AS (
  SELECT city_name, country_code, city_id FROM UNNEST([
    STRUCT('Głogów' AS city_name, 'gv-pl' AS country_code, 27 AS city_id),
    STRUCT('Slobozia', 'gv-ro', 33),
    STRUCT('Skierniewice', 'gv-pl', 103),
    STRUCT('Konin', 'gv-pl', 151),
    STRUCT('Corbeanca', 'gv-ro', 29),
    STRUCT('Resita', 'gv-ro', 3),
    STRUCT('Bouznika', 'gv-ma', 8),
    STRUCT('Oskemen/ust-kamenogorsk', 'gv-kz', 9),
    STRUCT('Van od', 't3', 98),
    STRUCT('Żory', 'gv-pl', 31),
    STRUCT('Dębica', 'gv-pl', 81),
    STRUCT('Brovary', 'gv-ua', 43)
  ])
),

applicants_t AS (
  SELECT
    a.country_code,
    a.city_id,
    a.approved_at AS hired_date,
    a.rider_id
  FROM `fulfillment-dwh-production.cl.applicants` a
  INNER JOIN city_lookup cl ON a.country_code = cl.country_code AND a.city_id = cl.city_id
  WHERE a.created_at >= '2026-01-01'
    AND a.approved_at IS NOT NULL
),

orders AS (
  SELECT
    country_code,
    rider_id,
    created_date_local,
    SUM(SUM(B.completed_deliveries)) OVER(
      PARTITION BY rider_id, country_code ORDER BY created_date_local
    ) AS cum_orders
  FROM `fulfillment-dwh-production.cl.rider_kpi` A
  , UNNEST(deliveries) B
  WHERE hiring_date_local >= '2026-01-01'
  GROUP BY country_code, rider_id, created_date_local
),

raf_payments AS (
  SELECT
    country_code,
    B.referee_id AS rider_id,
    MAX(CASE WHEN B.status IN ('PAID','PENDING') THEN 1 ELSE 0 END) AS enrolled_raf,
    SUM(CASE WHEN B.status IN ('PAID','PENDING') THEN B.total_eur ELSE 0 END) AS raf_paid_eur
  FROM `fulfillment-dwh-production.cl.rider_referral_payments` A
  , UNNEST(payment_details) B
  GROUP BY 1, 2
),

nhb_payments AS (
  SELECT
    country_code,
    P.rider_id,
    MAX(CASE WHEN d.status IN ('PAID','PENDING') THEN 1 ELSE 0 END) AS enrolled_nhb,
    SUM(CASE WHEN d.status IN ('PAID','PENDING') THEN d.total_eur ELSE 0 END) AS nhb_paid_eur
  FROM `fulfillment-dwh-production.cl.rider_new_hire_benefit_payments` P
  , UNNEST(payment_details) d
  WHERE DATE(d.paid_period_start, P.timezone) >= '2026-01-01'
  GROUP BY 1, 2
),

elf_comms AS (
  SELECT
    country_code,
    SAFE_CAST(user.id AS INT64) AS rider_id,
    1 AS elf_reached
  FROM `fulfillment-dwh-production.cl.digital_communication`
  WHERE created_date >= '2026-01-01'
    AND campaign_name LIKE 'ELF_%'
  GROUP BY 1, 2
),

rider_agg AS (
  SELECT
    cl.city_name,
    a.country_code,
    a.rider_id,
    MAX(raf.enrolled_raf)  AS enrolled_raf,
    SUM(raf.raf_paid_eur)  AS raf_paid_eur,
    MAX(nhb.enrolled_nhb)  AS enrolled_nhb,
    SUM(nhb.nhb_paid_eur)  AS nhb_paid_eur,
    MAX(elf.elf_reached)   AS elf_reached,
    MIN(CASE WHEN o.cum_orders >= 1   THEN o.created_date_local END) AS date_first_order,
    MIN(CASE WHEN o.cum_orders >= 100 THEN o.created_date_local END) AS date_100_orders,
    DATE_DIFF(
      DATE(MIN(CASE WHEN o.cum_orders >= 1 THEN o.created_date_local END)),
      DATE(a.hired_date), DAY
    ) AS days_to_activation,
    DATE_DIFF(
      DATE(MIN(CASE WHEN o.cum_orders >= 100 THEN o.created_date_local END)),
      DATE(a.hired_date), DAY
    ) AS days_to_adoption
  FROM applicants_t a
  INNER JOIN city_lookup cl ON a.country_code = cl.country_code AND a.city_id = cl.city_id
  LEFT JOIN orders o         ON a.country_code = o.country_code AND a.rider_id = o.rider_id
  LEFT JOIN raf_payments raf ON a.country_code = raf.country_code AND a.rider_id = raf.rider_id
  LEFT JOIN nhb_payments nhb ON a.country_code = nhb.country_code AND a.rider_id = nhb.rider_id
  LEFT JOIN elf_comms elf    ON a.country_code = elf.country_code AND a.rider_id = elf.rider_id
  GROUP BY 1, 2, 3, a.hired_date
)

SELECT
  city_name,
  country_code,

  -- Volume
  COUNT(DISTINCT rider_id)                                                              AS hired_riders,

  -- Activation (1st order)
  COUNT(DISTINCT CASE WHEN date_first_order IS NOT NULL THEN rider_id END)             AS activated_riders,
  ROUND(SAFE_DIVIDE(
    COUNT(DISTINCT CASE WHEN date_first_order IS NOT NULL THEN rider_id END),
    COUNT(DISTINCT rider_id)), 3)                                                       AS activation_rate,
  ROUND(AVG(CASE WHEN date_first_order IS NOT NULL THEN days_to_activation END), 1)   AS avg_days_to_activation,

  -- Adoption (100 orders)
  COUNT(DISTINCT CASE WHEN date_100_orders IS NOT NULL THEN rider_id END)              AS adopted_riders,
  ROUND(SAFE_DIVIDE(
    COUNT(DISTINCT CASE WHEN date_100_orders IS NOT NULL THEN rider_id END),
    COUNT(DISTINCT rider_id)), 3)                                                       AS adoption_rate,
  ROUND(AVG(CASE WHEN date_100_orders IS NOT NULL THEN days_to_adoption END), 1)      AS avg_days_to_adoption,

  -- Incentive enrollment
  COUNTIF(enrolled_raf = 1)                                                            AS enrolled_raf,
  ROUND(SAFE_DIVIDE(COUNTIF(enrolled_raf = 1), COUNT(DISTINCT rider_id)), 3)          AS raf_penetration,
  COUNTIF(enrolled_nhb = 1)                                                            AS enrolled_nhb,
  ROUND(SAFE_DIVIDE(COUNTIF(enrolled_nhb = 1), COUNT(DISTINCT rider_id)), 3)          AS nhb_penetration,
  COUNTIF(elf_reached = 1)                                                             AS elf_reached,
  ROUND(SAFE_DIVIDE(COUNTIF(elf_reached = 1), COUNT(DISTINCT rider_id)), 3)           AS elf_penetration,

  -- Spend
  ROUND(SUM(raf_paid_eur), 2)                                                          AS total_raf_eur,
  ROUND(SUM(nhb_paid_eur), 2)                                                          AS total_nhb_eur

FROM rider_agg
GROUP BY 1, 2
ORDER BY hired_riders DESC
