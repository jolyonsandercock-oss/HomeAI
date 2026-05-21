-- =============================================================================
-- V194 — U176 cash variance + U177 VAT return prep
-- =============================================================================

BEGIN;

-- U176: cash variance unexplained 7d (uses till_reconciliation if available)
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'cash_variance_unexplained_7d',
  'Cash variance — unexplained > £10 (last 7 days)',
  'U176: per-till per-day variances > £10 needing investigation.',
  E'SELECT * FROM v_cash_variance_day
     WHERE transaction_date BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE - 1
       AND ABS(variance_pence) > 1000
     ORDER BY transaction_date DESC, ABS(variance_pence) DESC',
  '{}', 'shared', true, NOW(), 'u176', 'u176'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

-- U176: cash drift per till 30d
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'cash_drift_per_till_30d',
  'Cash drift — per till, last 30 days',
  'U176: per-till variance summary. Which till most/least reliable.',
  E'SELECT
      site,
      till_id,
      count(*)            AS days_reconciled,
      SUM(ABS(variance_pence))::numeric(12,0) / 100.0 AS total_abs_variance_gbp,
      AVG(variance_pence)::numeric(10,2) / 100.0  AS avg_variance_gbp,
      count(*) FILTER (WHERE ABS(variance_pence) > 1000) AS days_over_10
    FROM v_cash_variance_day
    WHERE transaction_date > CURRENT_DATE - 30
    GROUP BY site, till_id
    ORDER BY total_abs_variance_gbp DESC NULLS LAST',
  '{}', 'shared', true, NOW(), 'u176', 'u176'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

-- U177: VAT return prep view per quarter
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'vat_return_quarter',
  'VAT return prep — quarter view',
  'U177: full output VAT + input VAT for any quarter (default = current). Param :for_date in the quarter.',
  E'WITH q AS (
      SELECT date_trunc(''quarter'', :for_date::date)::date AS q_start,
             (date_trunc(''quarter'', :for_date::date) + INTERVAL ''3 months'' - INTERVAL ''1 day'')::date AS q_end
    ),
    -- Output VAT (sales)
    food_out AS (
      SELECT SUM(value)::numeric(12,2) AS gross,
             SUM(value * COALESCE(vat_rate, 0.20) / (1 + COALESCE(vat_rate, 0.20)))::numeric(12,2) AS vat_out
        FROM touchoffice_department_sales, q
       WHERE report_date BETWEEN q.q_start AND q.q_end
    ),
    rooms_out AS (
      SELECT SUM(rate_per_night)::numeric(12,2) AS gross,
             SUM(rate_per_night * 0.20 / 1.20)::numeric(12,2) AS vat_out
        FROM caterbook_room_nights, q
       WHERE night_date BETWEEN q.q_start AND q.q_end
    ),
    -- Input VAT (purchases)
    bills_in AS (
      SELECT SUM(total)::numeric(12,2) AS gross,
             SUM(tax_total)::numeric(12,2) AS vat_in
        FROM xero_bills, q
       WHERE invoice_date BETWEEN q.q_start AND q.q_end
    )
    SELECT
      (SELECT q_start FROM q) AS quarter_start,
      (SELECT q_end FROM q) AS quarter_end,
      ((SELECT gross FROM food_out) + (SELECT gross FROM rooms_out))::numeric(12,2) AS total_revenue_gross,
      ((SELECT vat_out FROM food_out) + (SELECT vat_out FROM rooms_out))::numeric(12,2) AS output_vat,
      (SELECT gross FROM bills_in) AS total_purchases_gross,
      (SELECT vat_in FROM bills_in) AS input_vat,
      (((SELECT vat_out FROM food_out) + (SELECT vat_out FROM rooms_out)) - COALESCE((SELECT vat_in FROM bills_in), 0))::numeric(12,2) AS net_vat_due',
  '{"for_date": {"type": "string", "format": "date", "default": "2026-05-21"}}',
  'shared', true, NOW(), 'u177', 'u177'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, param_schema = EXCLUDED.param_schema, approved_at = NOW();

COMMIT;
