-- V217 — U232 Track 3 (increment 1): self-contained COGS capture-completeness signal
--
-- Goal: flag months whose captured COGS is too incomplete for GP% to be trusted
-- (e.g. Jan 2026 had zero captured invoices -> a fake 100% GP). This increment
-- deliberately depends ONLY on `purchases` — NOT on bank outflow.
--
-- Why not bank-anchored (the original plan): bank_transactions is ~10k rows but
-- ~99% are tagged realm='personal' (only 87 work rows / £66k vs £4.28M personal),
-- which is the same systemic realm mis-classification seen on invoices. A true
-- captured-vs-paid coverage ratio needs that fixed first. Tracked as a follow-up
-- in .claude/sprints/U232-cogs-capture-completeness.md. This view is the honest,
-- shippable interim: relative completeness, not absolute coverage.
--
-- security_invoker=true so RLS applies as the calling role (U147 Phase A lesson).

CREATE OR REPLACE VIEW v_cogs_capture_coverage
WITH (security_invoker = true) AS
WITH monthly AS (
  SELECT date_trunc('month', p.invoice_date)::date AS month,
         round(sum(pl.line_net), 2)        AS captured_cogs,
         count(DISTINCT p.id)              AS invoice_count,
         count(DISTINCT p.vendor_name)     AS vendor_count
  FROM purchases p
  JOIN purchase_lines pl ON pl.purchase_id = p.id
  WHERE p.is_invoice AND p.gate_passed AND p.realm = 'work'
    AND p.invoice_date IS NOT NULL
  GROUP BY 1
),
withavg AS (
  SELECT m.*,
         round(avg(m.captured_cogs) OVER (
           ORDER BY m.month ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING
         ), 2) AS prev3_avg_cogs
  FROM monthly m
)
SELECT
  month,
  captured_cogs,
  invoice_count,
  vendor_count,
  prev3_avg_cogs,
  CASE WHEN prev3_avg_cogs IS NULL OR prev3_avg_cogs = 0 THEN NULL
       ELSE round(captured_cogs / prev3_avg_cogs * 100, 0)
  END AS pct_of_prev3,
  -- completeness status used by the frontend to qualify GP%
  CASE
    WHEN captured_cogs IS NULL OR captured_cogs = 0 THEN 'empty'
    WHEN prev3_avg_cogs IS NOT NULL AND prev3_avg_cogs > 0
         AND captured_cogs < prev3_avg_cogs * 0.5            THEN 'low'
    ELSE 'ok'
  END AS completeness
FROM withavg
ORDER BY month DESC;

COMMENT ON VIEW v_cogs_capture_coverage IS
  'U232 T3 increment 1: per-month captured COGS (work realm) with a trailing-3mo '
  'completeness flag (empty/low/ok). Relative signal to qualify GP%; NOT absolute '
  'coverage (bank-anchored version blocked on bank realm re-classification).';

-- Whitelisted slug
INSERT INTO query_whitelist (slug, sql_template, param_schema, realm, active, display_name, created_by)
VALUES (
  'cogs_capture_coverage',
  'SELECT month, captured_cogs, invoice_count, vendor_count, prev3_avg_cogs, pct_of_prev3, completeness
     FROM v_cogs_capture_coverage
    WHERE month >= date_trunc(''month'', CURRENT_DATE) - (COALESCE(:months, 12) || '' months'')::interval
    ORDER BY month DESC',
  '{"months": {"type": "integer", "required": false}}'::jsonb,
  'work', true, 'COGS capture coverage (monthly)', 'U232'
)
ON CONFLICT (slug) DO UPDATE
  SET sql_template = EXCLUDED.sql_template,
      param_schema = EXCLUDED.param_schema,
      realm        = EXCLUDED.realm,
      active       = true;

UPDATE query_whitelist SET approved_at = NOW() WHERE slug = 'cogs_capture_coverage';
