/*====================================================================
  BATCH DISTRIBUTION & MOBILITY — Scheduled Table Version
====================================================================
  TABLE: Maripaz.batch_distribution_mobility_weekly

  PURPOSE: Single source table for the Milestone 1 Looker Studio dashboard.
  SCHEDULE: Run weekly (Monday morning after scoring completes).
  WINDOW:   Rolling 52 weeks (1 year) ending the Monday before today.

  GRAIN: one row per week × city × current batch × direction vs 12 weeks prior.

  DASHBOARD USE:
    - Batch distribution  → GROUP BY batch_label,  SUM(riders)
    - Mobility overview   → GROUP BY direction,     SUM(riders)
    - Batch × mobility    → GROUP BY batch_label + direction (e.g. "how many
                            batch-1 riders improved?")
    - % calculations      → Looker Studio: SUM(CASE WHEN batch_label='X' THEN riders END) / SUM(riders)
    - Sorting batch_label → use batch_sort (INT64); 'No Batch' sorts last (999)
    - Denominators        → total_riders = city-scoped; use SUM(riders) in Looker Studio for filter-aware %

  direction values:
    '0_New'            = first active week within 14 days of week_start
    '1_Improved'       = current batch < batch 12 wks ago  (lower number = better)
    '2_Maintained'     = unchanged
    '3_Declined'       = current batch > batch 12 wks ago
    '4_No Prior Batch' = has current batch but no valid prior batch AND not new
    'No Batch'         = no batch assignment (batch_num = 0 or NULL)
====================================================================*/

CREATE OR REPLACE TABLE `logistics-data-storage-staging.Maripaz.batch_distribution_mobility_weekly` AS

WITH

country_dim AS (
  SELECT country_code, region, region_short_name
  FROM `fulfillment-dwh-production.cl.countries`
),

-- One row per rider per week; includes riders with and without batch
weekly_batch AS (
  SELECT
    DATE_TRUNC(created_date_local, WEEK(MONDAY)) AS week_start,
    r.country_code,
    r.city_id,
    r.city_name,
    CASE
      WHEN r.country_code = 'sa' AND r.city_id = 209         THEN 'Hungerstation'
      WHEN r.country_code = 'ec' AND r.city_id IN (1, 2)     THEN 'PedidosYa'
      WHEN r.country_code = 'ph' AND r.city_id IN (1, 3)     THEN 'Pandora'
      WHEN r.country_code = 'ae' AND r.city_id IN (201, 202) THEN 'Talabat UAE'
      WHEN r.country_code = 'om' AND r.city_id = 211         THEN 'Talabat Oman'
      ELSE NULL
    END AS canary_tag,
    r.rider_id,
    MAX(r.batch_number) AS batch_num
  FROM `fulfillment-dwh-production.cl.rider_kpi` r
  WHERE r.country_code != 'de2'
    AND r.created_date_local >= DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 52 WEEK)
    AND r.created_date_local <  DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY))
    AND r.planned_working_time > 0
  GROUP BY 1, 2, 3, 4, 5, 6
),

-- First week each rider appeared with scheduled shifts in each city
-- Used to identify truly new riders (≤ 14 days since first shift)
rider_first_week AS (
  SELECT
    rider_id,
    country_code,
    city_id,
    MIN(week_start) AS first_week
  FROM weekly_batch
  GROUP BY 1, 2, 3
),

-- Pair each rider's current batch with their batch 12 weeks prior
-- Only riders with a valid current batch (batch_num > 0)
mobility_pairs AS (
  SELECT
    curr.week_start,
    DATE_SUB(curr.week_start, INTERVAL 12 WEEK) AS reference_week,
    curr.country_code,
    curr.city_id,
    curr.city_name,
    curr.canary_tag,
    curr.rider_id,
    curr.batch_num AS current_batch,
    prev.batch_num AS prev_batch,
    rfw.first_week
  FROM weekly_batch curr
  LEFT JOIN weekly_batch prev
    ON  curr.rider_id     = prev.rider_id
    AND curr.country_code = prev.country_code
    AND curr.city_id      = prev.city_id
    AND prev.week_start   = DATE_SUB(curr.week_start, INTERVAL 12 WEEK)
  LEFT JOIN rider_first_week rfw
    ON  curr.rider_id     = rfw.rider_id
    AND curr.country_code = rfw.country_code
    AND curr.city_id      = rfw.city_id
  WHERE curr.batch_num IS NOT NULL
    AND curr.batch_num > 0
),

-- Aggregated batch + mobility for riders with a valid batch
aggregated AS (
  SELECT
    week_start,
    reference_week,
    country_code,
    city_id,
    city_name,
    canary_tag,
    CAST(current_batch AS STRING) AS batch_label,
    CASE
      WHEN DATE_DIFF(week_start, first_week, DAY) <= 14  THEN '0_New'
      WHEN prev_batch IS NULL OR prev_batch = 0          THEN '4_No Prior Batch'
      WHEN current_batch < prev_batch                    THEN '1_Improved'
      WHEN current_batch = prev_batch                    THEN '2_Maintained'
      WHEN current_batch > prev_batch                    THEN '3_Declined'
    END AS direction,
    COUNT(*)                                                              AS riders,
    SUM(COUNT(*)) OVER (PARTITION BY week_start, country_code, city_id)  AS total_riders
  FROM mobility_pairs
  GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
),

-- Riders with no batch assignment (batch_num = 0 or NULL)
no_batch_agg AS (
  SELECT
    week_start,
    DATE_SUB(week_start, INTERVAL 12 WEEK)                               AS reference_week,
    country_code,
    city_id,
    city_name,
    canary_tag,
    'No Batch'                                                            AS batch_label,
    'No Batch'                                                            AS direction,
    COUNT(*)                                                              AS riders,
    SUM(COUNT(*)) OVER (PARTITION BY week_start, country_code, city_id)  AS total_riders
  FROM weekly_batch
  WHERE batch_num IS NULL OR batch_num = 0
  GROUP BY 1, 2, 3, 4, 5, 6
)

SELECT
  a.week_start,
  a.reference_week,
  a.country_code,
  a.city_id,
  a.city_name,
  a.canary_tag,
  CASE
    WHEN a.country_code IN (
      'bd','hk','kh','la','mm','my','ph','pk','sg','tw',
      'at','ca','de','fi','no','se','sk','tr','t3','cz','hu','vn'
    )                                                      THEN 'Pandora'
    WHEN a.country_code IN ('ae','bh','eg','iq','jo','kw','om','qa') THEN 'Talabat'
    WHEN a.country_code = 'sa'                             THEN 'Hungerstation'
    WHEN a.country_code IN (
      'ar','bo','cl','cr','do','ec','gt','hn','ni','py','pe','sv','uy','ve','pa'
    )                                                      THEN 'PedidosYa'
    WHEN STARTS_WITH(a.country_code, 'gv-')                THEN 'Glovo'
    ELSE 'Other'
  END AS vertical,
  cd.region,
  cd.region_short_name,
  a.batch_label,
  CASE
    WHEN a.batch_label = 'No Batch' THEN 999
    ELSE CAST(a.batch_label AS INT64)
  END                                                                     AS batch_sort,
  a.direction,
  a.riders,
  a.total_riders
FROM (
  SELECT * FROM aggregated
  UNION ALL
  SELECT * FROM no_batch_agg
) a
LEFT JOIN country_dim cd ON a.country_code = cd.country_code
ORDER BY a.week_start, a.country_code, a.city_id, batch_sort, a.direction;
