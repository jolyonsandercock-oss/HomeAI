-- V213__projB_daily_cogs_7d.sql — daily purchase-based COGS (is_cogs categories,
-- work realm) with a 7-day rolling average. WIP: purchase date ≠ consumption, and
-- capture is partial, so this is a smoothed approximation (shown italic on /sales).
INSERT INTO query_whitelist (slug, display_name, sql_template, param_schema, realm, entity_id, created_by, active, approved_at)
VALUES ('daily_cogs_7d_avg', 'Daily COGS 7d rolling avg',
$sql$
WITH daily AS (
  SELECT p.invoice_date AS day, sum(pl.line_net) AS cogs
  FROM purchases p JOIN purchase_lines pl ON pl.purchase_id = p.id
  LEFT JOIN cogs_category_map m ON m.purchase_category = COALESCE(pl.category, p.category)
  WHERE p.gate_passed AND p.is_invoice AND p.realm='work' AND p.invoice_date IS NOT NULL
    AND COALESCE(m.is_cogs, false)
  GROUP BY 1
),
s AS (SELECT d::date AS day FROM generate_series(CURRENT_DATE - 60, CURRENT_DATE, '1 day') d)
SELECT s.day,
       round(COALESCE(daily.cogs,0),2) AS cogs_day,
       round(avg(COALESCE(daily.cogs,0)) OVER (ORDER BY s.day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW),2) AS cogs_7d_avg
FROM s LEFT JOIN daily ON daily.day = s.day
ORDER BY s.day DESC
$sql$,
'{}'::jsonb, 'work', 1, 'projB-V213', true, NOW())
ON CONFLICT (slug) DO UPDATE SET sql_template=EXCLUDED.sql_template, approved_at=NOW();
