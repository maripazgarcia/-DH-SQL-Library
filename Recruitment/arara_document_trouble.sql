-- Document friction analysis: which documents are most frequently reuploaded or rejected per city
-- Scope: 2026-01-01 to present
-- Cities: Kelantan (my), Ankara od (t3), Sylhet (bd), Sialkot (pk), Ciudad de guatemala (gt)
-- Usage: pinpoints which specific Arara documents cause friction (resubmission, rejection, ghosting after rejection)
-- Note: reject_documents counts documents where recruiter explicitly rejected; reupload_documents counts
--       applicant-side re-attempts. High rejected + low reuploaded = rider ghosted after doc failure.

WITH city_applicants AS (
  SELECT applicant_id, country_code,
    CASE
      WHEN country_code = 'my' AND city_id = 216 THEN 'Kelantan'
      WHEN country_code = 't3' AND city_id = 4   THEN 'Ankara od'
      WHEN country_code = 'bd' AND city_id = 2   THEN 'Sylhet'
      WHEN country_code = 'pk' AND city_id = 206 THEN 'Sialkot'
      WHEN country_code = 'gt' AND city_id = 1   THEN 'Ciudad de guatemala'
    END AS city_name
  FROM `fulfillment-dwh-production.cl.applicants`
  WHERE created_at >= '2026-01-01'
    AND (
      (country_code = 'my' AND city_id = 216) OR
      (country_code = 't3' AND city_id = 4)   OR
      (country_code = 'bd' AND city_id = 2)   OR
      (country_code = 'pk' AND city_id = 206) OR
      (country_code = 'gt' AND city_id = 1)
    )
),

uploaded AS (
  SELECT l.applicant_id, l.country_code, doc
  FROM `fulfillment-dwh-production.cl.applicants_activity_logs` l
  , UNNEST(l.upload_documents.documents_type) doc
  WHERE l.action_name = 'Upload Document'
    AND l.created_date >= '2026-01-01'
    AND l.country_code IN ('my', 't3', 'bd', 'pk', 'gt')
),

reuploaded AS (
  SELECT l.applicant_id, l.country_code, doc
  FROM `fulfillment-dwh-production.cl.applicants_activity_logs` l
  , UNNEST(l.reupload_documents.documents_type) doc
  WHERE l.action_name = 'Reupload Document'
    AND l.created_date >= '2026-01-01'
    AND l.country_code IN ('my', 't3', 'bd', 'pk', 'gt')
),

rejected_docs AS (
  SELECT l.applicant_id, l.country_code, doc
  FROM `fulfillment-dwh-production.cl.applicants_activity_logs` l
  , UNNEST(l.reject_documents.documents_type) doc
  WHERE l.action_name = 'Reject Document'
    AND l.created_date >= '2026-01-01'
    AND l.country_code IN ('my', 't3', 'bd', 'pk', 'gt')
)

SELECT
  ca.city_name,
  ca.country_code,
  u.doc                                                                                   AS document_type,
  COUNT(DISTINCT u.applicant_id)                                                          AS applicants_uploaded,
  COUNT(DISTINCT r.applicant_id)                                                          AS applicants_reuploaded,
  COUNT(DISTINCT rd.applicant_id)                                                         AS applicants_rejected,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT r.applicant_id), COUNT(DISTINCT u.applicant_id)), 3)  AS reupload_rate
FROM city_applicants ca
INNER JOIN uploaded u      ON ca.applicant_id = u.applicant_id AND ca.country_code = u.country_code
LEFT JOIN reuploaded r     ON ca.applicant_id = r.applicant_id AND ca.country_code = r.country_code AND u.doc = r.doc
LEFT JOIN rejected_docs rd ON ca.applicant_id = rd.applicant_id AND ca.country_code = rd.country_code AND u.doc = rd.doc
GROUP BY 1, 2, 3
ORDER BY city_name, applicants_reuploaded DESC;
