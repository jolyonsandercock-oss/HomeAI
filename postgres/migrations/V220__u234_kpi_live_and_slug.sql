-- V220 — U234: live KPI values + kpi_dashboard slug (traffic-light + levers)

-- Pro-rata salaried labour cost for a window [w_start, w_end] (inclusive),
-- with optional employer on-cost uplift. Excludes nobody here — it is ADDED to
-- hourly labour, while the hourly side excludes salaried staff by external id.
CREATE OR REPLACE FUNCTION home_ai.salaried_cost(w_start date, w_end date)
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT COALESCE(sum(
    (annual_salary * (1 + on_cost_pct/100.0) / 365.0)
    * GREATEST(0, (LEAST(COALESCE(end_date, w_end), w_end)
                   - GREATEST(start_date, w_start) + 1))
  ), 0)
  FROM salaried_staff
  WHERE realm IN ('work','shared')
    AND start_date <= w_end
    AND (end_date IS NULL OR end_date >= w_start);
$$;

-- Live value per KPI (each on its natural window). security_invoker so RLS
-- applies as the caller. Labour EXCLUDES salaried staff's hourly Tanda shifts
-- (matched by user_external_id) and ADDS their salary pro-rata instead.
CREATE OR REPLACE VIEW v_kpi_live WITH (security_invoker = true) AS
WITH
sales7  AS (SELECT COALESCE(sum(value),0) v FROM touchoffice_department_sales WHERE report_date >  CURRENT_DATE-7),
salesp7 AS (SELECT COALESCE(sum(value),0) v FROM touchoffice_department_sales WHERE report_date >  CURRENT_DATE-14 AND report_date <= CURRENT_DATE-7),
sales30 AS (SELECT COALESCE(sum(value),0) v FROM touchoffice_department_sales WHERE report_date >  CURRENT_DATE-30),
lab7  AS (SELECT COALESCE(sum(cost_estimate),0) + home_ai.salaried_cost(CURRENT_DATE-6,  CURRENT_DATE) v
          FROM workforce_shifts
          WHERE shift_date > CURRENT_DATE-7  AND shift_date <= CURRENT_DATE
            AND user_external_id::text NOT IN (SELECT workforce_external_id FROM salaried_staff WHERE workforce_external_id IS NOT NULL AND realm IN ('work','shared'))),
lab30 AS (SELECT COALESCE(sum(cost_estimate),0) + home_ai.salaried_cost(CURRENT_DATE-29, CURRENT_DATE) v
          FROM workforce_shifts
          WHERE shift_date > CURRENT_DATE-30 AND shift_date <= CURRENT_DATE
            AND user_external_id::text NOT IN (SELECT workforce_external_id FROM salaried_staff WHERE workforce_external_id IS NOT NULL AND realm IN ('work','shared'))),
cogs30 AS (SELECT COALESCE(sum(pl.line_net),0) v
           FROM purchases p JOIN purchase_lines pl ON pl.purchase_id=p.id
           WHERE p.realm='work' AND p.is_invoice AND p.gate_passed AND p.invoice_date > CURRENT_DATE-30),
gpf AS (SELECT gp_pct FROM v_gross_margin_period WHERE dept='FOOD SALES'    ORDER BY month DESC LIMIT 1),
gpw AS (SELECT gp_pct FROM v_gross_margin_period WHERE dept='ALCOHOL SALES' ORDER BY month DESC LIMIT 1),
cov AS (SELECT pct_of_prev3 FROM v_cogs_capture_coverage ORDER BY month DESC LIMIT 1),
cashup AS (SELECT abs(variance) v FROM till_reconciliation ORDER BY recon_date DESC, created_at DESC LIMIT 1)
SELECT 'labour_pct'::text kpi_key,    round(100.0*(SELECT v FROM lab7)/NULLIF((SELECT v FROM sales7),0),1) value
UNION ALL SELECT 'sales_vs_lw',       round(100.0*((SELECT v FROM sales7)-(SELECT v FROM salesp7))/NULLIF((SELECT v FROM salesp7),0),1)
UNION ALL SELECT 'prime_cost',        round(100.0*((SELECT v FROM cogs30)+(SELECT v FROM lab30))/NULLIF((SELECT v FROM sales30),0),1)
UNION ALL SELECT 'food_gp',           (SELECT gp_pct FROM gpf)
UNION ALL SELECT 'wet_gp',            (SELECT gp_pct FROM gpw)
UNION ALL SELECT 'cogs_coverage',     (SELECT pct_of_prev3 FROM cov)
UNION ALL SELECT 'cashup_variance',   (SELECT v FROM cashup);

GRANT SELECT ON v_kpi_live TO homeai_readonly;

-- Slug: join live values to targets, derive traffic-light status + lever
INSERT INTO query_whitelist (slug, sql_template, param_schema, realm, active, display_name, created_by)
VALUES (
  'kpi_dashboard',
  $q$
  SELECT t.kpi_key, t.label, t.tier, t.unit, t.direction,
         l.value, t.green_bound, t.amber_bound, t.window_note, t.provisional, t.sort_order,
         CASE
           WHEN l.value IS NULL THEN 'nodata'
           WHEN t.direction='higher_better' THEN
             CASE WHEN l.value >= t.green_bound THEN 'green'
                  WHEN l.value >= t.amber_bound THEN 'amber' ELSE 'red' END
           ELSE
             CASE WHEN l.value <= t.green_bound THEN 'green'
                  WHEN l.value <= t.amber_bound THEN 'amber' ELSE 'red' END
         END AS status,
         CASE
           WHEN l.value IS NULL THEN NULL
           WHEN t.direction='higher_better' AND l.value <  t.amber_bound THEN t.lever_red
           WHEN t.direction='higher_better' AND l.value <  t.green_bound THEN t.lever_amber
           WHEN t.direction='lower_better'  AND l.value >  t.amber_bound THEN t.lever_red
           WHEN t.direction='lower_better'  AND l.value >  t.green_bound THEN t.lever_amber
           ELSE NULL
         END AS lever
  FROM kpi_targets t
  LEFT JOIN v_kpi_live l USING (kpi_key)
  WHERE t.active AND (:tier::text IS NULL OR t.tier = :tier)
  ORDER BY t.sort_order
  $q$,
  '{"tier": {"type": "string", "required": false}}'::jsonb,
  'work', true, 'KPI dashboard (traffic-light + levers)', 'U234'
)
ON CONFLICT (slug) DO UPDATE
  SET sql_template = EXCLUDED.sql_template, param_schema = EXCLUDED.param_schema,
      realm = EXCLUDED.realm, active = true;
UPDATE query_whitelist SET approved_at = NOW() WHERE slug = 'kpi_dashboard';
