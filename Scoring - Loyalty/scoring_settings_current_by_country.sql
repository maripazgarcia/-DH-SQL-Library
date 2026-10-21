-- Current active KPI weights per country (averaged across cities)
-- Source: fulfillment-dwh-production.cl._scoring_settings
-- Billing project: dhub-data-commune

SELECT
  country_code,
  COUNT(DISTINCT city_id) AS cities_count,
  ROUND(AVG(s.kpi_weight_acceptance), 1)              AS avg_weight_acceptance,
  ROUND(AVG(s.kpi_weight_actual_to_planned_hours), 1) AS avg_weight_actual_to_planned_hours,
  ROUND(AVG(s.kpi_weight_special_hours), 1)           AS avg_weight_special_hours,
  ROUND(AVG(s.kpi_weight_no_show), 1)                 AS avg_weight_no_show,
  ROUND(AVG(s.kpi_weight_utr), 1)                     AS avg_weight_utr,
  ROUND(AVG(s.kpi_weight_hours), 1)                   AS avg_weight_hours,
  ROUND(AVG(s.kpi_weight_deliveries), 1)              AS avg_weight_deliveries,
  ROUND(AVG(s.kpi_weight_late_login), 1)              AS avg_weight_late_login,
  ROUND(AVG(s.kpi_weight_tenure), 1)                  AS avg_weight_tenure,
  ROUND(AVG(s.kpi_weight_manual_undispatches), 1)     AS avg_weight_manual_undispatches
FROM `fulfillment-dwh-production.cl._scoring_settings`,
UNNEST(scoring_settings) AS s
WHERE s.is_active = TRUE
GROUP BY country_code
ORDER BY country_code
