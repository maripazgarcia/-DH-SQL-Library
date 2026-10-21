-- Arara stage funnel: workflow diversity, stage completion, rejection rates, and document friction
-- Scope: 2026-01-01 to present
-- Cities: Kelantan (my), Ankara od (t3), Sylhet (bd), Sialkot (pk), Ciudad de guatemala (gt)
-- Usage: identifies where applicants drop or are rejected in the hiring funnel, and how many workflows are active per city

-- Part 1: Workflow diversity summary (how many workflows, which dominates)
SELECT
  city_name,
  country_code,
  workflow_name,
  COUNT(DISTINCT stage_name) AS stages_in_workflow,
  SUM(applicants)            AS total_applicants
FROM `fulfillment-dwh-production.rl.rider_recruitment`
WHERE _source = 'stage_name_details'
  AND city_name IN ('Kelantan', 'Ankara od', 'Sylhet', 'Sialkot', 'Ciudad de guatemala')
  AND report_week >= '2026-01'
GROUP BY 1, 2, 3
ORDER BY city_name, total_applicants DESC;


-- Part 2: Stage-level funnel with completion, rejection and document friction
SELECT
  city_name,
  country_code,
  workflow_name,
  tier,
  index_in_tier,
  stage_name,
  stage_type,
  SUM(applicants)                                                                          AS applicants_in_stage,
  SUM(stages_completed)                                                                    AS completed,
  SUM(is_rejected)                                                                         AS rejected,
  ROUND(SAFE_DIVIDE(SUM(stages_completed), SUM(applicants)), 3)                           AS completion_rate,
  ROUND(SAFE_DIVIDE(SUM(is_rejected), SUM(applicants)), 3)                                AS rejection_rate,
  ROUND(SAFE_DIVIDE(SUM(time_to_complete_stage), SUM(applicants)) / 86400, 1)            AS avg_days_to_complete,
  ROUND(SAFE_DIVIDE(SUM(time_to_stage), SUM(applicants)) / 86400, 1)                     AS avg_days_to_reach,
  SUM(uploaded_documents)                                                                  AS docs_uploaded,
  SUM(reuploaded_documents)                                                                AS docs_reuploaded,
  SUM(rejected_documents)                                                                  AS docs_rejected,
  ROUND(SAFE_DIVIDE(SUM(reuploaded_documents), NULLIF(SUM(uploaded_documents), 0)), 3)   AS reupload_rate
FROM `fulfillment-dwh-production.rl.rider_recruitment`
WHERE _source = 'stage_name_details'
  AND city_name IN ('Kelantan', 'Ankara od', 'Sylhet', 'Sialkot', 'Ciudad de guatemala')
  AND report_week >= '2026-01'
GROUP BY 1, 2, 3, 4, 5, 6, 7
ORDER BY city_name, workflow_name, tier, index_in_tier;
