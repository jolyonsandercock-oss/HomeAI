-- V248 — pipeline drift detector (Hermes HIGH #2/#5/#7). Surfaces the
-- silent-pipeline-failure class: a record that should have produced a downstream
-- row but didn't (no retry, no dead-letter, no alert). The motivating case: a
-- Paperless 'invoice'/'utility_bill' document that never reached
-- vendor_invoice_inbox because the post-consume webhook silently failed (it sat
-- in `documents` for 7h, undetected). selftest now asserts this view is empty.
-- Extend with more UNION ALL branches as other expected-destination gaps appear.
-- Reversible: DROP VIEW home_ai.v_pipeline_drift;
BEGIN;

CREATE OR REPLACE VIEW home_ai.v_pipeline_drift AS
  -- invoice/bill documents (Paperless) with no vendor_invoice_inbox row after a
  -- 2h grace (the post-consume-webhook silent-failure class).
  SELECT 'doc_not_invoiced'::text AS drift_type,
         d.id                     AS ref_id,
         d.category               AS detail,
         d.created_at             AS since
  FROM documents d
  WHERE d.category IN ('invoice','utility_bill')
    AND NOT EXISTS (
      SELECT 1 FROM vendor_invoice_inbox v WHERE v.paperless_doc_id = d.id)
    AND d.created_at < now() - interval '2 hours';

COMMIT;
