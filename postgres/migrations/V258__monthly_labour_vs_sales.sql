-- =============================================================================
-- V258 — monthly labour-vs-sales trend (WORK / entity 1)
-- =============================================================================
-- Rolls up worked-shift labour cost against net sales by calendar month.
--
-- IMPORTANT — base wage, pre-on-cost:
--   labour_base_cost = SUM(workforce_shifts.award_cost) for WORKED shifts.
--   award_cost is Workforce's base wage (rate-at-time x hours), EXCLUDING
--   on-costs (holiday/NI/pension). Leave entries (hours NULL) contribute £0 by
--   design — their cost is accrued onto worked hours via the on-cost uplift, so
--   counting them would double-count holiday.
--   Once the Workforce token gains the `settings` scope (planned 2026-06-11) and
--   we know the real on-cost %, the loaded figure is labour_base_cost*(1+pct).
--
-- net_sales = SUM(v_daily_unit_economics.total_revenue) (pub + sandwich + accom,
-- net). Months where sales scrape coverage is thin (e.g. 2026-01) will show a
-- misleadingly high labour% — read sales_days alongside labour%.
-- =============================================================================

BEGIN;

CREATE OR REPLACE VIEW v_monthly_labour_vs_sales AS
WITH lab AS (
  SELECT date_trunc('month', shift_date)::date AS month,
         count(DISTINCT shift_date)                                  AS labour_days,
         round(sum(award_cost) FILTER (WHERE hours_worked IS NOT NULL), 2) AS labour_base_cost,
         round(sum(hours_worked), 1)                                 AS hours_worked,
         count(*) FILTER (WHERE hours_worked IS NULL)                AS leave_entries
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
  s.sales_days,
  s.net_sales,
  s.pub_net_sales,
  CASE WHEN s.net_sales > 0
       THEN round(100 * l.labour_base_cost / s.net_sales, 1)
       END                                                AS labour_pct_base
FROM lab l
FULL OUTER JOIN sales s ON s.month = l.month
ORDER BY 1;

COMMENT ON VIEW v_monthly_labour_vs_sales IS
  'Monthly worked-shift labour cost (base wage, pre-on-cost) vs net sales. labour_pct_base excludes on-costs (holiday/NI/pension) pending the Workforce settings-scope token (~2026-06-11). Watch sales_days: thin months (e.g. 2026-01) inflate labour%.';

COMMIT;
