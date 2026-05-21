-- =============================================================================
-- V161 — fix entity_isolation_lines RLS policy on vendor_invoice_lines
-- =============================================================================
-- The existing policy expression is:
--   EXISTS (... AND (current_setting('app.current_entity', true) = 'all'
--                    OR v.entity_id = (NULLIF(current_setting(...), ''))::integer))
--
-- Postgres does NOT short-circuit OR. When app.current_entity = 'all' (the
-- default for the homeai_readonly role), the planner still evaluates the
-- second branch — 'all'::integer — and errors with
--   "invalid input syntax for type integer: 'all'"
-- as soon as any query against vendor_invoice_lines runs as homeai_readonly.
--
-- The sibling policy on vendor_invoice_inbox uses a CASE/regex guard that
-- gates the integer cast behind a digit-only check. Mirror that here.
-- =============================================================================

BEGIN;

DROP POLICY IF EXISTS entity_isolation_lines ON vendor_invoice_lines;

CREATE POLICY entity_isolation_lines ON vendor_invoice_lines
  USING (
    EXISTS (
      SELECT 1
        FROM vendor_invoice_inbox v
       WHERE v.id = vendor_invoice_lines.invoice_id
         AND (
           CASE
             WHEN current_setting('app.current_entity', true) = 'all'      THEN TRUE
             WHEN current_setting('app.current_entity', true) ~ '^\d+$'    THEN v.entity_id = (current_setting('app.current_entity', true))::integer
             ELSE FALSE
           END
         )
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
        FROM vendor_invoice_inbox v
       WHERE v.id = vendor_invoice_lines.invoice_id
         AND (
           CASE
             WHEN current_setting('app.current_entity', true) = 'all'      THEN TRUE
             WHEN current_setting('app.current_entity', true) ~ '^\d+$'    THEN v.entity_id = (current_setting('app.current_entity', true))::integer
             ELSE FALSE
           END
         )
    )
  );

COMMIT;
