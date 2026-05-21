-- =============================================================================
-- V166 — U138 Phase B + C: invoice-lines slug + orphan slug realm flips
-- =============================================================================
-- Phase B: new slug `invoice_lines(invoice_id)` over v_invoice_lines_resolved
--          for /app/admin/invoices/[id] drilldown.
-- Phase C: re-tag 4 existing slugs (xero orphans + invoice headers + pending
--          invoices) from realm=owner → realm=shared so the /app/* dashboard
--          (request realm = 'work') can read them.
-- =============================================================================

BEGIN;

-- ---------- Phase B slug ----------------------------------------------------
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, result_format,
   active, created_by, approved_at, approved_by, notes, realm, intent_examples)
VALUES
('invoice_lines',
 'U138 — line items for one invoice',
 'Full line-item detail for a single vendor_invoice_inbox row. Joins to product_canonical for family/name. Used by /app/admin/invoices/[id].',
 $sql$SELECT line_id, line_no, raw_description AS description,
              qty, unit, unit_price,
              line_net, line_vat, line_gross,
              canonical_id, canonical_family, canonical_name,
              extracted_by, extraction_confidence
         FROM v_invoice_lines_resolved
        WHERE invoice_id = :invoice_id::bigint
        ORDER BY line_no$sql$,
 '{"invoice_id":{"type":"int","required":true}}'::jsonb,
 'table', true, 'u138', NOW(), 'u138', NULL, 'shared',
 ARRAY['invoice lines','line items','what was on the invoice']);

-- ---------- Phase C slug realm flips ----------------------------------------
UPDATE query_whitelist SET realm = 'shared'
 WHERE slug IN ('xero_vs_email_orphans','xero_orphans_top_vendors','xero_bills_recent','pending_invoices');

-- ---------- One more slug we'll need: invoice header (single row) ----------
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, result_format,
   active, created_by, approved_at, approved_by, notes, realm, intent_examples)
VALUES
('invoice_header',
 'U138 — single-invoice header row',
 'One row of vendor_invoice_inbox detail for the drilldown page header. Includes Xero link state, paperless id, attachment count.',
 $sql$SELECT id, vendor_name, vendor_domain, account, subject,
              received_at, invoice_date, due_date, delivery_date,
              gross_amount, net_amount, vat_amount, vat_rate,
              category_canonical, site, status,
              has_pdf, attachment_count, first_attachment_path,
              paperless_doc_id, xero_bill_id,
              forwarded_to_dext_at,
              extraction_method, extraction_confidence, extracted_at,
              notes
         FROM vendor_invoice_inbox
        WHERE id = :invoice_id::bigint$sql$,
 '{"invoice_id":{"type":"int","required":true}}'::jsonb,
 'table', true, 'u138', NOW(), 'u138', NULL, 'shared',
 ARRAY['invoice header','invoice detail']);

COMMIT;
