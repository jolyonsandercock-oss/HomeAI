-- =============================================================================
-- V263 — surface ON-COSTED labour in the monthly trend (V262 follow-up)
-- =============================================================================
-- V258 reported base wage (award_cost). Now that V262 puts the full on-costed
-- figure in cost_estimate (= award_cost × 1.2692, matching the Workforce report),
-- the trend should lead with on-costed labour. Base kept for reference.
--
-- NB: labour_pct_oncosted uses our net_sales (v_daily_unit_economics), whose
-- revenue basis differs from Workforce's "Revenue Actual" (e.g. May: ours
-- £185,974 vs Workforce £151,516.82) — so labour% won't equal Workforce's
-- Timesheet-Wage-% until that revenue basis is reconciled (separate task).
-- =============================================================================

BEGIN;

DROP VIEW IF EXISTS v_monthly_labour_vs_sales;
CREATE VIEW v_monthly_labour_vs_sales AS
WITH lab AS (
  SELECT date_trunc('month', shift_date)::date AS month,
         count(DISTINCT shift_date)                                          AS labour_days,
         round(sum(hours_worked), 1)                                         AS hours_worked,
         count(*) FILTER (WHERE hours_worked IS NULL)                        AS leave_entries,
         round(sum(award_cost) FILTER (WHERE hours_worked IS NOT NULL), 2)   AS labour_base_cost,
         round(sum(cost_estimate) FILTER (WHERE hours_worked IS NOT NULL), 2) AS labour_oncosted
  FROM workforce_shifts
  WHERE award_cost IS NOT NULL OR hours_worked IS NULL
  GROUP BY 1
),
sales AS (
  SELECT date_trunc('month', report_date)::date AS month,
         count(*) FILTER (WHERE total_revenue > 0)        AS sales_days,
         round(sum(total_revenue), 2)                     AS net_sales,
         round(sum(pub_net_sales), 2)                     AS pub_net_sales
  FROM v_daily_unit_economics
  WHERE report_date <= CURRENT_DATE
  GROUP BY 1
)
SELECT
  COALESCE(l.month, s.month)                              AS month,
  l.labour_days,
  l.hours_worked,
  l.leave_entries,
  l.labour_base_cost,
  l.labour_oncosted,
  s.sales_days,
  s.net_sales,
  s.pub_net_sales,
  CASE WHEN s.net_sales > 0
       THEN round(100 * l.labour_oncosted / s.net_sales, 1) END AS labour_pct_oncosted,
  CASE WHEN s.net_sales > 0
       THEN round(100 * l.labour_base_cost / s.net_sales, 1) END AS labour_pct_base
FROM lab l
FULL OUTER JOIN sales s ON s.month = l.month
ORDER BY 1;

COMMENT ON VIEW v_monthly_labour_vs_sales IS
  'Monthly labour vs net sales. labour_oncosted = award_cost × (1+workforce.on_cost_pct) (Workforce-report-matched, V262); labour_base_cost = base wage. Leave excluded. labour_pct uses our net_sales basis (differs from Workforce Revenue Actual — revenue reconciliation pending).';

COMMIT;
