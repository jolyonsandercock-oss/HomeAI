-- =============================================================================
-- V116 — U84: keep the row that already has extracted lines as canonical
-- =============================================================================
-- V115 ranking preferred (pdf_local_path) > (has lines). That meant some
-- already-extracted rows got demoted to 'duplicate' while a sibling with
-- only the PDF became canonical — pointless work for u61 to redo.
--
-- Swap pairs where the demoted row has lines and the keeper doesn't:
--   - Promote the row with lines to status='extracted', canonical_id=self
--   - Demote the previous keeper to status='duplicate', canonical_id=former-demoted
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

WITH bad_pairs AS (
  -- Rows marked 'duplicate' that have lines, where their canonical doesn't
  SELECT
    dup.id           AS demoted_id,
    dup.canonical_id AS keeper_id,
    dup.status       AS demoted_status_before
  FROM vendor_invoice_inbox dup
  WHERE dup.status = 'duplicate'
    AND dup.canonical_id IS NOT NULL
    AND EXISTS (SELECT 1 FROM vendor_invoice_lines vl WHERE vl.invoice_id = dup.id)
    AND NOT EXISTS (SELECT 1 FROM vendor_invoice_lines vl WHERE vl.invoice_id = dup.canonical_id)
),
promote AS (
  -- Promote the row with lines back to extracted (or to keep its previous state)
  UPDATE vendor_invoice_inbox v
     SET status = 'extracted',
         canonical_id = v.id
    FROM bad_pairs b
   WHERE v.id = b.demoted_id
   RETURNING v.id
),
demote AS (
  -- Demote the former keeper to duplicate, pointing at the now-canonical
  UPDATE vendor_invoice_inbox v
     SET status = 'duplicate',
         canonical_id = b.demoted_id
    FROM bad_pairs b
   WHERE v.id = b.keeper_id
   RETURNING v.id
)
SELECT
  'V116 promoted ' || (SELECT COUNT(*) FROM promote) || ' lines-having rows' ||
  '; demoted ' || (SELECT COUNT(*) FROM demote) || ' former keepers'
  AS result;

COMMIT;
