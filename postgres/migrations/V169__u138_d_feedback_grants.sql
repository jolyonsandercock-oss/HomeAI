-- =============================================================================
-- V169 — U138 Phase D-ii: GRANTs for line_category_feedback writes.
-- =============================================================================
-- The homeai-frontend connects as homeai_readonly. The new POST
-- /api/feedback/line endpoint needs to INSERT into line_category_feedback
-- and UPDATE three columns on vendor_invoice_lines.
--
-- Realm + entity isolation are still enforced — these GRANTs don't bypass
-- RLS, just make the SQL not error on permission_denied.
-- =============================================================================

BEGIN;

GRANT INSERT, SELECT, UPDATE ON line_category_feedback   TO homeai_readonly;
GRANT USAGE, SELECT ON SEQUENCE line_category_feedback_id_seq TO homeai_readonly;
GRANT UPDATE (department, canonical_id, suggested_family) ON vendor_invoice_lines TO homeai_readonly;

COMMIT;
