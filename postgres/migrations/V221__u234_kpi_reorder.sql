-- V221 — U234: reorder the KPI band so RELIABLE KPIs lead and PROVISIONAL
-- (muted) ones trail. The dashboard opens with this band; leading with the
-- grey "data incomplete" cards (prime cost, labour %, food/wet GP) read weak,
-- so sales-vs-last-week + coverage (both reliable) now come first.
UPDATE kpi_targets SET sort_order = CASE kpi_key
  WHEN 'sales_vs_lw'     THEN 10
  WHEN 'cogs_coverage'   THEN 20
  WHEN 'prime_cost'      THEN 30
  WHEN 'labour_pct'      THEN 40
  WHEN 'food_gp'         THEN 50
  WHEN 'wet_gp'          THEN 60
  WHEN 'cashup_variance' THEN 70
  ELSE sort_order END;
