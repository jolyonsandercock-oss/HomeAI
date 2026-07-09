-- V304 (2026-07-09) — permanent 'no-pdf' marker for statement recon.
--
-- ~102 is_statement rows (2022-era Bidfresh/Sidetrade/relay emails) carry
-- .xls or link-only statements — no PDF attachment exists, so the daily
-- u296 run re-errored on all of them every morning ("gmail-fetch-failed",
-- errors=102 in every ops note). u296 now retires such docs with a
-- match_method='no-pdf' marker row; transient fetch errors still retry.
ALTER TABLE statement_recon_lines DROP CONSTRAINT IF EXISTS statement_recon_lines_match_method_check;
ALTER TABLE statement_recon_lines ADD CONSTRAINT statement_recon_lines_match_method_check
  CHECK (match_method = ANY (ARRAY['invoice_number'::text, 'date_amount'::text,
                                   'unmatched'::text, 'duplicate'::text, 'no-pdf'::text]));

-- Marker rows are bookkeeping, not statement lines: exclude them from
-- line counts and capture % exactly like 'duplicate'.
CREATE OR REPLACE VIEW v_statement_capture_rate AS
SELECT
  vendor_key                                                       AS vendor,
  count(DISTINCT statement_id)                                     AS statements,
  count(*) FILTER (WHERE match_method NOT IN ('duplicate','no-pdf')) AS lines,
  count(*) FILTER (WHERE matched_invoice_id IS NOT NULL)            AS matched,
  count(*) FILTER (WHERE match_method = 'unmatched')                AS missing,
  round(
    100.0 * count(*) FILTER (WHERE matched_invoice_id IS NOT NULL)
    / NULLIF(count(*) FILTER (WHERE match_method NOT IN ('duplicate','no-pdf')), 0), 1
  )                                                                 AS capture_pct,
  coalesce(sum(line_amount) FILTER (WHERE match_method = 'unmatched'), 0) AS missing_value
FROM statement_recon_lines
GROUP BY vendor_key
ORDER BY missing_value DESC NULLS LAST;
