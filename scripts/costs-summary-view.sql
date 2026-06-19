-- costs-summary-view.sql — Phase 3.3. Rolling daily/7d/30d cost & income summary.
-- Income from v_daily_cost_vs_sales (TouchOffice head_office); cost-by-category from the
-- now-categorised invoices (net_dry=food, net_wet=drink, net_cafe, overhead=repairs+
-- utilities+software+other); labour from workforce_shifts.cost_estimate (26.92% on-cost,
-- the canonical basis — NOT v_daily_labour_by_team's stale 12.5%). Calendar date-spine
-- so 7d/30d windows are true calendar days even on no-trade days.
-- NOTE: purchases (invoice/delivery dated) are a COGS proxy; the 7/30d rolling smooths
-- the lumpy delivery timing against daily sales (this is why Jo wanted rolling).
CREATE OR REPLACE VIEW mart.v_costs_summary_daily AS
WITH spine AS (
  SELECT generate_series(date '2025-01-01', current_date, '1 day')::date AS report_date
),
lab AS (
  SELECT shift_date, sum(cost_estimate)::numeric(12,2) AS labour
  FROM workforce_shifts GROUP BY 1
),
daily AS (
  SELECT s.report_date,
    COALESCE(cs.total_revenue,0)::numeric AS income,
    COALESCE(cs.net_dry,0)::numeric  AS food,
    COALESCE(cs.net_wet,0)::numeric  AS drink,
    COALESCE(cs.net_cafe,0)::numeric AS cafe,
    (COALESCE(cs.net_repairs,0)+COALESCE(cs.net_utilities,0)+COALESCE(cs.net_software,0)+COALESCE(cs.net_other,0))::numeric AS overhead,
    COALESCE(l.labour,0)::numeric AS labour
  FROM spine s
  LEFT JOIN v_daily_cost_vs_sales cs ON cs.report_date = s.report_date
  LEFT JOIN lab l ON l.shift_date = s.report_date
),
calc AS (
  SELECT *, (food+drink+cafe) AS cogs, (food+drink+cafe+labour+overhead) AS total_cost
  FROM daily
)
SELECT report_date,
  -- daily
  round(income,2) income, round(food,2) food, round(drink,2) drink, round(cafe,2) cafe,
  round(cogs,2) cogs, round(labour,2) labour, round(overhead,2) overhead,
  round(income-cogs,2) gross_profit,
  CASE WHEN income>0 THEN round(100*(income-cogs)/income,1) END AS gp_pct,
  round(income-total_cost,2) AS residual,
  -- 7-day rolling AVERAGES (calendar)
  round(avg(income)    OVER w7,2) income_7d_avg,
  round(avg(cogs)      OVER w7,2) cogs_7d_avg,
  round(avg(labour)    OVER w7,2) labour_7d_avg,
  round(avg(overhead)  OVER w7,2) overhead_7d_avg,
  -- 7-day rolling TOTALS
  round(sum(income)   OVER w7,2) income_7d_total,
  round(sum(cogs)     OVER w7,2) cogs_7d_total,
  round(sum(labour)   OVER w7,2) labour_7d_total,
  round(sum(overhead) OVER w7,2) overhead_7d_total,
  CASE WHEN sum(income) OVER w7>0 THEN round(100*(sum(income) OVER w7 - sum(cogs) OVER w7)/sum(income) OVER w7,1) END AS gp_pct_7d,
  CASE WHEN sum(income) OVER w7>0 THEN round(100*sum(labour) OVER w7/sum(income) OVER w7,1) END AS labour_pct_7d,
  CASE WHEN sum(income) OVER w7>0 THEN round(100*(sum(income) OVER w7 - sum(income-overhead-cogs-labour) OVER w7)/sum(income) OVER w7,1) END AS cost_pct_7d,
  -- 30-day rolling
  round(avg(income)   OVER w30,2) income_30d_avg,
  round(avg(cogs)     OVER w30,2) cogs_30d_avg,
  round(avg(labour)   OVER w30,2) labour_30d_avg,
  round(avg(overhead) OVER w30,2) overhead_30d_avg,
  round(sum(income)   OVER w30,2) income_30d_total,
  round(sum(cogs)     OVER w30,2) cogs_30d_total,
  round(sum(labour)   OVER w30,2) labour_30d_total,
  round(sum(overhead) OVER w30,2) overhead_30d_total,
  CASE WHEN sum(income) OVER w30>0 THEN round(100*(sum(income) OVER w30 - sum(cogs) OVER w30)/sum(income) OVER w30,1) END AS gp_pct_30d,
  CASE WHEN sum(income) OVER w30>0 THEN round(100*sum(labour) OVER w30/sum(income) OVER w30,1) END AS labour_pct_30d,
  CASE WHEN sum(income) OVER w30>0 THEN round(100*(sum(income) OVER w30 - sum(income-total_cost) OVER w30)/sum(income) OVER w30,1) END AS total_cost_pct_30d
FROM calc
WINDOW w7  AS (ORDER BY report_date ROWS BETWEEN 6  PRECEDING AND CURRENT ROW),
       w30 AS (ORDER BY report_date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW)
ORDER BY report_date DESC;
