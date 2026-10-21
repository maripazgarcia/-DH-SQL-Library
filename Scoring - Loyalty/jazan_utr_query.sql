-- UTR for Jazan (sa / city 209) as used in the "Where the orders came from" slide (updated 2026-10-07: ALL working hours, orders completed).
-- Hours = every working hour of the week (all days, not only days with a planned shift) of riders who had at least one
-- delivery that week. Deliveries = orders completed (completed_deliveries on every row, no notification condition).
-- Change country_code/city_id for any other city. Slide figures = simple average of the weekly values over the 12 weeks
-- before launch (2026-05-11 .. 2026-07-27) and the complete weeks since (2026-08-03 .. 2026-09-28).
WITH hrs AS (
  SELECT DATE_TRUNC(created_date_local, WEEK(MONDAY)) AS week_start, rider_id, SUM(working_time) / 3600 AS hours
  FROM `fulfillment-dwh-production.cl.rider_kpi`
  WHERE country_code = 'sa' AND city_id = 209
    AND created_date_local BETWEEN '2026-05-11' AND '2026-09-27'
  GROUP BY 1, 2
),
del AS (
  SELECT DATE_TRUNC(r.created_date_local, WEEK(MONDAY)) AS week_start, r.rider_id, SUM(d.completed_deliveries) AS completed
  FROM `fulfillment-dwh-production.cl.rider_kpi` r, UNNEST(r.deliveries) AS d
  WHERE r.country_code = 'sa' AND r.city_id = 209
    AND r.created_date_local BETWEEN '2026-05-11' AND '2026-09-27'
  GROUP BY 1, 2
)
SELECT week_start,
       COUNT(*)                                          AS riders,
       SUM(completed)                                    AS completed_deliveries,
       ROUND(SUM(hours), 1)                              AS working_hours,
       ROUND(SAFE_DIVIDE(SUM(completed), SUM(hours)), 2) AS utr
FROM del JOIN hrs USING (week_start, rider_id)
WHERE hours > 0
GROUP BY 1
ORDER BY 1;
