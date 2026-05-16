-- =============================================================================
-- V115 — U84: deduplicate invoices that arrived via multiple mailboxes
-- =============================================================================
-- Problem: Forest Produce / many other vendors email invoices to BOTH
-- admin@malthousetintagel.com AND info@malthousetintagel.com. Each gets
-- harvested separately and counted as a distinct invoice. Today's audit:
-- 3,188 rows across 1,320 clusters are content-duplicates.
--
-- Definition of content-duplicate:
--   (vendor_domain, subject, amount_seen) all match across rows that
--   aren't already 'duplicate' or 'ignored'.
--
-- Keeper selection (in order):
--   1. The one with pdf_local_path (PDF actually downloaded)
--   2. The one with extracted line items
--   3. Lowest id (= earliest received)
--
-- Losing copies: status='duplicate' + canonical_id points at the keeper.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

-- Add canonical_id column if missing (for cross-link to the kept row)
ALTER TABLE vendor_invoice_inbox
  ADD COLUMN IF NOT EXISTS canonical_id BIGINT;

-- Stage the dedup decision in a temp table for atomic apply.
CREATE TEMP TABLE _dedup_decisions AS
WITH content_keys AS (
  SELECT
    v.id,
    v.vendor_domain || '|' || COALESCE(v.subject,'') || '|' || COALESCE(v.amount_seen::text,'?') AS ck,
    -- Rank: PDF on disk > has extracted lines > oldest id
    ROW_NUMBER() OVER (
      PARTITION BY v.vendor_domain || '|' || COALESCE(v.subject,'') || '|' || COALESCE(v.amount_seen::text,'?')
      ORDER BY
        (v.pdf_local_path IS NOT NULL) DESC,
        (EXISTS(SELECT 1 FROM vendor_invoice_lines vl WHERE vl.invoice_id=v.id)) DESC,
        v.id ASC
    ) AS rk,
    v.id AS row_id
  FROM vendor_invoice_inbox v
  WHERE v.status NOT IN ('duplicate','ignored')
    AND v.vendor_domain IS NOT NULL
    AND v.subject IS NOT NULL
),
clusters_with_dups AS (
  SELECT ck FROM content_keys GROUP BY ck HAVING COUNT(*) > 1
)
SELECT
  ck.id,
  ck.ck,
  ck.rk,
  -- Keeper id = the rk=1 row in the same cluster
  FIRST_VALUE(ck.id) OVER (PARTITION BY ck.ck ORDER BY ck.rk) AS keeper_id
FROM content_keys ck
WHERE ck.ck IN (SELECT ck FROM clusters_with_dups);

-- Tag the losers
WITH bumped AS (
  UPDATE vendor_invoice_inbox v
     SET status = 'duplicate',
         canonical_id = d.keeper_id
    FROM _dedup_decisions d
   WHERE v.id = d.id
     AND d.rk > 1
     AND v.status NOT IN ('duplicate', 'ignored')
   RETURNING v.id
)
SELECT 'V115 marked ' || COUNT(*) || ' rows as duplicate' AS result FROM bumped;

-- Also link the keeper rows to themselves (canonical_id = own id) so a
-- consumer can always JOIN on canonical_id and reach the kept copy.
UPDATE vendor_invoice_inbox v
   SET canonical_id = v.id
  FROM _dedup_decisions d
 WHERE v.id = d.id
   AND d.rk = 1
   AND v.canonical_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_vii_canonical
  ON vendor_invoice_inbox(canonical_id)
  WHERE canonical_id IS NOT NULL;

COMMIT;
