-- V299 (2026-07-05) — kill the Capital-on-Tap self-forward loop, class-wide.
--
-- Mechanism found by the invoice-capture audit: u128-forward-orphans forwards
-- any 7-day-old inbox row with no xero_bill to Dext. A STATEMENT never gets a
-- xero_bill, so it always qualifies; the sent copy is re-ingested next morning
-- (05:50 classify sweep) as a NEW row, which forwards again the following day
-- ("Fwd: Fwd: Fwd: ..." x9 by 2026-07-05, £64,848 of recurring noise in naive
-- sums, one wasted Dext extraction per day).
--
-- Fix 1 (this view): statements are never Dext-forwardable. Fix 2 (already
-- shipped, u281 drain guard): statement-subject docs are never vision-extracted,
-- so future copies keep invoice_date NULL and can't qualify anyway. Fix 3
-- (data, below): retire the existing chain's forward eligibility.
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
            THEN true
            ELSE false
        END AS needs_forward
   FROM vendor_invoice_inbox i
  WHERE xero_bill_id IS NULL AND invoice_date IS NOT NULL AND invoice_date >= (CURRENT_DATE - 365);

-- Fix 3: no statement row may ever be forwarded — stamp the survivors so even
-- a view rollback can't resurrect the loop. (Idempotent.)
UPDATE vendor_invoice_inbox
   SET forwarded_to_dext_at = now()
 WHERE coalesce(is_statement, false) = true
   AND forwarded_to_dext_at IS NULL;
