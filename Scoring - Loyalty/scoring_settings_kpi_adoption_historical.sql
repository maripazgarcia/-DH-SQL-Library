-- Historical KPI adoption: how often each metric is used and its average weight
-- Source: fulfillment-dwh-production.cl._scoring_settings
-- Billing project: dhub-data-commune
-- Sorted by % of active configs currently using each KPI

WITH flat AS (
  SELECT
    country_code,
    city_id,
    s.is_active,
    s.kpi_weight_acceptance,
    s.kpi_weight_actual_to_planned_hours,
    s.kpi_weight_special_hours,
    s.kpi_weight_no_show,
    s.kpi_weight_utr,
    s.kpi_weight_hours,
    s.kpi_weight_deliveries,
    s.kpi_weight_late_login,
    s.kpi_weight_tenure,
    s.kpi_weight_manual_undispatches
  FROM `fulfillment-dwh-production.cl._scoring_settings`,
  UNNEST(scoring_settings) AS s
),
totals AS (
  SELECT
    COUNT(*) AS total_configs,
    COUNTIF(is_active) AS total_active_configs
  FROM flat
),
metrics AS (
  SELECT 'acceptance_rate'          AS kpi, kpi_weight_acceptance              AS w, is_active FROM flat UNION ALL
  SELECT 'actual_to_planned_hours'  AS kpi, kpi_weight_actual_to_planned_hours AS w, is_active FROM flat UNION ALL
  SELECT 'special_hours'            AS kpi, kpi_weight_special_hours            AS w, is_active FROM flat UNION ALL
  SELECT 'no_show'                  AS kpi, kpi_weight_no_show                  AS w, is_active FROM flat UNION ALL
  SELECT 'utr'                      AS kpi, kpi_weight_utr                      AS w, is_active FROM flat UNION ALL
  SELECT 'hours'                    AS kpi, kpi_weight_hours                    AS w, is_active FROM flat UNION ALL
  SELECT 'deliveries'               AS kpi, kpi_weight_deliveries               AS w, is_active FROM flat UNION ALL
  SELECT 'late_login'               AS kpi, kpi_weight_late_login               AS w, is_active FROM flat UNION ALL
  SELECT 'tenure'                   AS kpi, kpi_weight_tenure                   AS w, is_active FROM flat UNION ALL
  SELECT 'manual_undispatches'      AS kpi, kpi_weight_manual_undispatches      AS w, is_active FROM flat
)
SELECT
  m.kpi,
  ROUND(COUNTIF(m.w > 0) * 100.0 / MAX(t.total_configs), 1)                              AS pct_all_configs_using_it,
  ROUND(COUNTIF(m.w > 0 AND m.is_active) * 100.0 / MAX(t.total_active_configs), 1)       AS pct_active_configs_using_it,
  ROUND(AVG(IF(m.w > 0, m.w, NULL)), 1)                                                   AS avg_weight_when_used,
  ROUND(AVG(IF(m.w > 0 AND m.is_active, m.w, NULL)), 1)                                  AS avg_weight_when_used_active
FROM metrics m, totals t
GROUP BY m.kpi
ORDER BY pct_active_configs_using_it DESC
