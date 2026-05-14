-- =============================================================================
-- V66b — Realm audit views (R2)
-- =============================================================================
-- Two diagnostic views for the realm rollout:
--
--   v_realm_audit_violations — rows whose realm disagrees with the realm
--     implied by their entity_id (entity 1 → work; entities 2/3/4 → family).
--     Should be empty post-R1. A non-empty row count is a sign that ingest
--     tagging is drifting or that a manual UPDATE moved realm without
--     moving entity_id (or vice versa).
--
--   v_realm_policy_coverage — every realm-bearing public table and whether
--     it has a realm_isolation policy. Acceptance gate for the R2 rollout
--     and audit trail for future migrations that add new tables.
-- =============================================================================

BEGIN;

-- Note: `emails` is deliberately excluded from this audit. V64 derives
-- emails.realm from account-of-receipt (mailbox-of-receipt rule), not from
-- entity_id, because the realm-split spec treats mailbox-of-receipt as the
-- ingest-time realm source. Entity_id on emails is content-classifier output
-- and can legitimately disagree with realm (e.g. a pub-content email arriving
-- in jo@ — entity_id=1, realm=family).
CREATE OR REPLACE VIEW v_realm_audit_violations AS
WITH expected AS (
    SELECT 'events'::text AS t, ev.id::text AS row_id,
           CASE WHEN ev.entity_id = 1 THEN 'work'
                WHEN ev.entity_id IN (2,3,4) THEN 'family'
                ELSE 'owner' END AS expected_realm,
           ev.realm AS actual_realm
      FROM events ev
    UNION ALL
    SELECT 'invoices', i.id::text,
           CASE WHEN i.entity_id = 1 THEN 'work'
                WHEN i.entity_id IN (2,3,4) THEN 'family'
                ELSE 'owner' END,
           i.realm
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
   -- 'shared' tables/rows aren't expected to match entity-derived realm.
   AND actual_realm <> 'shared';

COMMENT ON VIEW v_realm_audit_violations IS
    'R2 audit: rows where realm disagrees with entity_id-implied realm. '
    'Empty in steady state. Non-empty = ingest tagging drift or manual edit.';


CREATE OR REPLACE VIEW v_realm_policy_coverage AS
WITH realm_tables AS (
    SELECT DISTINCT col.table_name
      FROM information_schema.columns col
      JOIN pg_class c ON c.relname = col.table_name AND c.relkind = 'r'
      JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = col.table_schema
     WHERE col.table_schema = 'public'
       AND col.column_name = 'realm'
       AND NOT c.relispartition
),
policied AS (
    SELECT DISTINCT tablename FROM pg_policies WHERE schemaname = 'public'
),
realm_policied AS (
    SELECT DISTINCT tablename, MAX(permissive) AS realm_policy_kind
      FROM pg_policies
     WHERE schemaname = 'public' AND policyname = 'realm_isolation'
     GROUP BY tablename
)
SELECT rt.table_name,
       (p.tablename IS NOT NULL) AS has_any_policy,
       (rp.tablename IS NOT NULL) AS has_realm_policy,
       rp.realm_policy_kind
  FROM realm_tables rt
  LEFT JOIN policied p ON p.tablename = rt.table_name
  LEFT JOIN realm_policied rp ON rp.tablename = rt.table_name
 ORDER BY rt.table_name;

COMMENT ON VIEW v_realm_policy_coverage IS
    'R2 audit: every realm-bearing public table (excluding partition '
    'children) and whether it carries a realm_isolation policy. Post-V65/V65b '
    'every row should have has_realm_policy = true.';

COMMIT;
