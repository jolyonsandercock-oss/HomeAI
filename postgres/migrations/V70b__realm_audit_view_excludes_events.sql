-- =============================================================================
-- V70b — v_realm_audit_violations: also exclude events from the entity_id-
-- based check, for the same reason as emails (V66b).
-- =============================================================================
-- After U53's R5 ingest tagging, events.realm is stamped by google-fetch from
-- the mailbox-of-receipt, not derived from entity_id. The audit view's
-- "expected" column built off entity_id therefore disagrees with the
-- (correct) actual realm for any pub-content email arriving in jo@ (events
-- end up entity_id=NULL or 1 but realm=family) and similar.
--
-- This migration rebuilds the view to drop events from the comparison, the
-- same way emails were dropped in V66b. We keep invoices /
-- vendor_invoice_inbox / bank_transactions / documents — those derive realm
-- from entity_id, so the entity-vs-realm check is the right yardstick.
-- =============================================================================

BEGIN;

CREATE OR REPLACE VIEW v_realm_audit_violations AS
WITH expected AS (
    SELECT 'invoices'::text AS t, i.id::text AS row_id,
           CASE WHEN i.entity_id = 1 THEN 'work'
                WHEN i.entity_id IN (2,3,4) THEN 'family'
                ELSE 'owner' END AS expected_realm,
           i.realm AS actual_realm
      FROM invoices i
    UNION ALL
    SELECT 'vendor_invoice_inbox', vii.id::text,
           CASE WHEN vii.entity_id = 1 THEN 'work'
                WHEN vii.entity_id IN (2,3,4) THEN 'family'
                ELSE 'owner' END,
           vii.realm
      FROM vendor_invoice_inbox vii
    UNION ALL
    SELECT 'bank_transactions', bt.id::text,
           CASE WHEN bt.entity_id = 1 THEN 'work'
                WHEN bt.entity_id IN (2,3,4) THEN 'family'
                ELSE 'owner' END,
           bt.realm
      FROM bank_transactions bt
    UNION ALL
    SELECT 'documents', d.id::text,
           CASE WHEN d.entity_id = 1 THEN 'work'
                WHEN d.entity_id IN (2,3,4) THEN 'family'
                ELSE 'owner' END,
           d.realm
      FROM documents d
)
SELECT t AS table_name, row_id, expected_realm, actual_realm
  FROM expected
 WHERE actual_realm <> expected_realm
   AND actual_realm <> 'shared';

COMMENT ON VIEW v_realm_audit_violations IS
    'R2/R5 audit: rows where realm disagrees with entity_id-implied realm. '
    'Excludes emails and events — those derive realm from mailbox-of-receipt '
    '(spec §2.5 ingest rule), so an entity_id comparison there is a category '
    'error.';

COMMIT;
