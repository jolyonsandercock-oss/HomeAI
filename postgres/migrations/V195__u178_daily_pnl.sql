-- =============================================================================
-- V195 — U178: daily P&L slug (revenue − costs − labour ≈ contribution)
-- =============================================================================

BEGIN;

INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'daily_pnl',
  'Daily P&L — revenue minus costs',
  'U178: per-day operational P&L. Revenue (rooms + food/drink) minus matched supplier spend (same day) and labour (workforce_shifts). Param :for_date (default yesterday).',
  E'WITH d AS (SELECT COALESCE(:for_date::date, CURRENT_DATE - 1) AS d),
    revenue AS (
      SELECT
        COALESCE((SELECT SUM(rate_per_night) FROM caterbook_room_nights, d WHERE night_date = d.d), 0)::numeric(12,2) AS rooms,
        COALESCE((SELECT SUM(value) FROM touchoffice_department_sales, d WHERE report_date = d.d), 0)::numeric(12,2) AS food_drink
    ),
    cost_supplier AS (
      SELECT COALESCE(SUM(total), 0)::numeric(12,2) AS spend
        FROM xero_bills xb, d
       WHERE xb.invoice_date = d.d
         AND xb.contact_name IN (
           ''St Austell Brewery'', ''J&R Food Services Ltd'',
           ''West Country Food Service'', ''Forest Produce'',
           ''Kingfisher Brixham'', ''Dole Foodservice Bodmin'',
           ''Quatra'', ''Hopwell Limited''
         )
    ),
    cost_labour AS (
      SELECT COALESCE(SUM(shift_cost), 0)::numeric(12,2) AS labour_gbp
        FROM workforce_shifts ws, d
       WHERE ws.start_time::date = d.d
    ),
    cards AS (
      SELECT COALESCE(SUM(transaction_amount), 0)::numeric(12,2) AS card_take
        FROM dojo_transactions, d
       WHERE transaction_date = d.d
         AND transaction_outcome = ''Authorised''
         AND transaction_type = ''Sale''
    )
    SELECT
      (SELECT d FROM d) AS for_date,
      (SELECT rooms FROM revenue) AS rooms_revenue,
      (SELECT food_drink FROM revenue) AS food_drink_revenue,
      ((SELECT rooms FROM revenue) + (SELECT food_drink FROM revenue))::numeric(12,2) AS total_revenue,
      (SELECT card_take FROM cards) AS card_take_today,
      (SELECT spend FROM cost_supplier) AS supplier_cost,
      (SELECT labour_gbp FROM cost_labour) AS labour_cost,
      (((SELECT rooms FROM revenue) + (SELECT food_drink FROM revenue))
       - (SELECT spend FROM cost_supplier)
       - (SELECT labour_gbp FROM cost_labour))::numeric(12,2) AS contribution',
  '{"for_date": {"type": "string", "format": "date"}}',
  'shared', true, NOW(), 'u178', 'u178'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, param_schema = EXCLUDED.param_schema, approved_at = NOW();

COMMIT;
