/*====================================================================
  QUERY: Loyalty orders vs Rider KPI orders — LatAm comparison
====================================================================
  PURPOSE:
    Compares the order count Loyalty uses to assign tiers
    (_rider_loyalty_tiers_performance.campaigns_latest_cumulative_orders)
    against an independently computed order count from rider_kpi,
    for the SAME campaign cycle window (local_cycle_start_date to
    local_cycle_end_date from the Loyalty tables themselves).
    Also recomputes the tier the rider WOULD be in under the
    rider_kpi count (using _rider_loyalty_milestone thresholds) and
    flags mismatches vs the tier Loyalty actually assigned.

  SCOPE: country_code IN (bo, ec, gt, hn, ni, pa, py), current cycle only
         (is_current_cycle = TRUE in _rider_loyalty_tiers_performance).

  KEY SCHEMA NOTE:
    campaign_id in _rider_loyalty_campaign / _rider_loyalty_milestone
    is NOT globally unique — it is unique per country_code (and, within
    _rider_loyalty_campaign, per city). Always join milestone to
    tiers_performance on (country_code, campaign_id) together, never
    campaign_id alone, or rows fan out across unrelated countries that
    happen to reuse the same numeric campaign_id.

  FINDINGS (run 2026-10-16, current cycles started Sep 2026):
    - BO/EC/GT/HN/PA/PY: discrepancies are small and roughly
      symmetric (median |diff| 0-1 orders, p95 ~6-8, p99 ~9-12 orders
      out of totals of 100-700+). Tier-mismatch rate 0.18-0.35%.
      Consistent with normal pipeline timing lag, not a data issue.
    - NI is the outlier: 22 riders (across city_id 1,2,3,4,5,6,14;
      16 of them in city_id 1 / Managua) with the Loyalty counter
      frozen while rider_kpi deliveries kept accruing normally.

  ROOT CAUSE (confirmed via _rider_loyalty_counter, 2026-10-16):
    - _rider_loyalty_tiers_performance.campaigns_latest_cumulative_orders
      is sourced 1:1 from _rider_loyalty_counter.delivery_counter for the
      rider's current-cycle counter_id (active = TRUE) — verified exact
      match on every affected rider, so this is NOT a warehouse
      aggregation bug.
    - For the 22 affected riders, that counter's updated_at stopped
      advancing entirely while the rider kept delivering: rider_kpi shows
      daily completed deliveries straight through 2026-10-15, but the
      counter row was never incremented again after its freeze date.
      As of 2026-10-15 this had accumulated 16-193 missed orders per
      rider (sum for the group ≈ 2,163 orders not credited).
    - 18 of the 22 froze on the SAME calendar day, 2026-10-08 (01:48-
      18:01 UTC), the rest on 2026-10-06/07 — i.e. an incident window,
      not independent per-rider failures. Ruled out: not tied to
      reaching the top (Diamond) milestone (none had — all were
      Silver/Gold at freeze, per _rider_loyalty_tier_achievement with
      counters well below their campaign's Diamond threshold); not a
      country/city-wide outage (the other ~2,800 riders in NI city_id 1
      alone have counters updating normally through 2026-10-16).
    - Reads as isolated stuck/orphaned counter rows — most likely a
      dropped or failed event in whatever consumer increments
      _rider_loyalty_counter.delivery_counter per completed delivery,
      clustered around 2026-10-06 to 2026-10-08 for NI. Could not go
      further from the warehouse side (no counter-mutation event log is
      exposed in cl.*) — needs the Loyalty service's own consumer/queue
      logs for that window to find why these 22 rider updates were
      dropped.
    - IMPACT: these riders are under-tiered relative to actual
      deliveries (e.g. rider 671792 shows Silver on 666 orders but has
      actually delivered 810 — past the 700-order Gold threshold for
      its campaign). Full list with counter_id and freeze timestamp:
      Deliverables/Loyalty vs Rider KPI Comparison/ni_outlier_riders.csv

  Swap the sample size (QUALIFY ... <= 8) or drop the sampled_riders
  CTE entirely to run against the full rider population (used for the
  country-level stats above — see the GROUP BY country_code variant).
====================================================================*/

WITH sampled_riders AS (
  SELECT
    country_code,
    city_id,
    city_name,
    rider_id,
    campaign_id,
    campaign_name,
    local_cycle_start_date,
    local_cycle_end_date,
    tier_name                            AS loyalty_tier,
    campaigns_latest_cumulative_orders   AS loyalty_orders
  FROM `fulfillment-dwh-production.cl._rider_loyalty_tiers_performance`
  WHERE LOWER(country_code) IN ('bo','ec','gt','hn','ni','pa','py')
    AND is_current_cycle = TRUE
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY country_code, city_id
    ORDER BY FARM_FINGERPRINT(CAST(rider_id AS STRING))
  ) <= 8
),

-- Independently computed order count from rider_kpi over the SAME
-- campaign cycle window Loyalty used (local_cycle_start_date/end_date).
kpi_orders AS (
  SELECT
    sr.country_code,
    sr.city_id,
    sr.rider_id,
    sr.campaign_id,
    SUM(d.completed_deliveries) AS kpi_orders
  FROM sampled_riders sr
  JOIN `fulfillment-dwh-production.cl.rider_kpi` r
    ON  r.country_code = sr.country_code
    AND r.city_id       = sr.city_id
    AND r.rider_id      = sr.rider_id
    AND r.created_date_local BETWEEN sr.local_cycle_start_date AND sr.local_cycle_end_date,
    UNNEST(r.deliveries) AS d
  GROUP BY 1,2,3,4
),

milestones AS (
  SELECT DISTINCT country_code, campaign_id, milestone_name, amount
  FROM `fulfillment-dwh-production.cl._rider_loyalty_milestone`
),

-- Tier the rider WOULD be in if rider_kpi's order count were used.
kpi_tier AS (
  SELECT
    k.country_code, k.city_id, k.rider_id, k.campaign_id,
    ARRAY_AGG(m.milestone_name ORDER BY m.amount DESC LIMIT 1)[OFFSET(0)] AS kpi_tier
  FROM kpi_orders k
  JOIN milestones m
    ON m.country_code = k.country_code
   AND m.campaign_id  = k.campaign_id
   AND m.amount <= k.kpi_orders
  GROUP BY 1,2,3,4
)

SELECT
  sr.country_code,
  sr.city_id,
  sr.city_name,
  sr.rider_id,
  sr.campaign_name,
  sr.local_cycle_start_date,
  sr.local_cycle_end_date,
  sr.loyalty_orders,
  IFNULL(ko.kpi_orders, 0)                           AS kpi_orders,
  IFNULL(ko.kpi_orders, 0) - sr.loyalty_orders        AS orders_diff,
  sr.loyalty_tier,
  IFNULL(kt.kpi_tier, 'Bronze')                       AS kpi_tier,
  CASE WHEN sr.loyalty_tier = IFNULL(kt.kpi_tier, 'Bronze') THEN 'MATCH' ELSE 'MISMATCH' END AS tier_match
FROM sampled_riders sr
LEFT JOIN kpi_orders ko USING (country_code, city_id, rider_id, campaign_id)
LEFT JOIN kpi_tier   kt USING (country_code, city_id, rider_id, campaign_id)
ORDER BY country_code, city_id, rider_id;
