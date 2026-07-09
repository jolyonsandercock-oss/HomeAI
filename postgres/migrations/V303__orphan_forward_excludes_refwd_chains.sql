-- V303 (2026-07-09) — kill the Fwd-chain self-forward loop, class-wide.
--
-- V299 stopped the STATEMENT self-forward loop, but two non-statement chains
-- kept looping ("Invoice copies — re: your 'missing invoices' list" and the
-- Hodgsons "re statements" arrears letter, is_statement flapping per copy):
-- u128-forward-orphans sends the doc to Dext, the sent copy is re-ingested
-- next morning as a NEW inbox row, and because invoice_date is extracted from
-- the (old) PDF the new row is instantly >7 days old and re-qualifies. By
-- 2026-07-09 both chains were at "Fwd: x15", forwarding daily at 02:30.
--
-- Class-wide invariant: a subject carrying two or more "Fwd:" prefixes is a
-- re-ingested forward copy, never an original vendor email. Each chain gets
-- at most one (already-sent) forward and then dies; legitimate single
-- forwards (Jo forwarding a supplier email from his phone) are unaffected.
CREATE OR REPLACE VIEW v_xero_orphan_inbox AS
 SELECT id AS inbox_id,
    vendor_name,
    invoice_date,
    gross_amount,
    amount_seen,
    account,
    source_email_id,
    received_at,
    first_attachment_path,
    forwarded_to_dext_at,
    CURRENT_DATE - invoice_date AS age_days,
        CASE
            WHEN invoice_date < (CURRENT_DATE - 7)
                 AND forwarded_to_dext_at IS NULL
                 AND coalesce(is_statement, false) = false
                 AND subject !~* '^\s*(fwd:\s*){2,}'
            THEN true
            ELSE false
        END AS needs_forward
   FROM vendor_invoice_inbox i
  WHERE xero_bill_id IS NULL AND invoice_date IS NOT NULL AND invoice_date >= (CURRENT_DATE - 365);

-- Data: retire the existing chains so a view rollback can't resurrect them.
-- (Idempotent — only touches unforwarded multi-Fwd rows.)
UPDATE vendor_invoice_inbox
   SET forwarded_to_dext_at = now()
 WHERE subject ~* '^\s*(fwd:\s*){2,}'
   AND forwarded_to_dext_at IS NULL;
