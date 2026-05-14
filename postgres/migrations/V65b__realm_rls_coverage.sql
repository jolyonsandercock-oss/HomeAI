-- =============================================================================
-- V65b — Realm RLS coverage for tables without an existing policy (R2)
-- =============================================================================
-- V65 layered RESTRICTIVE realm_isolation onto the 43 tables that already had
-- an entity-level policy. This migration handles the rest: every realm-bearing
-- table that has NO RLS policy gets ENABLE ROW LEVEL SECURITY plus a single
-- PERMISSIVE realm_isolation policy.
--
-- PERMISSIVE here (vs RESTRICTIVE in V65) because there is no co-existing
-- entity_isolation to AND-compose against — realm_isolation is the only
-- filter, and PG requires at least one PERMISSIVE policy or every row is
-- denied.
--
-- Transitional NULL/empty app.current_realm branch is identical to V65:
-- pass-through TRUE, so behaviour is unchanged until services opt in.
--
-- Scope:
--   * Tables in information_schema.columns with a `realm` column AND no
--     existing pg_policies entry.
--   * Partition children (events_2026_*, events_overflow) are explicitly
--     SKIPPED in this migration. RLS on partitioned tables in PG15 applies
--     to queries routed through the parent, which is the standard path for
--     all current Home AI code. A separate migration (V65c, queued in U53)
--     will enable RLS on the partitions for the rare case of direct-
--     partition queries — out of scope here to keep blast radius small.
--
-- Verification: every realm-bearing public table (excluding partition
-- children) ends with at least one policy.
-- =============================================================================

BEGIN;

DO $body$
DECLARE
    r RECORD;
    skip_partitions CONSTANT TEXT[] := ARRAY[
        'events_2026_04','events_2026_05','events_2026_06','events_2026_07',
        'events_overflow'
    ];
    realm_expr CONSTANT TEXT := $expr$
        CASE
            WHEN current_setting('app.current_realm', true) = 'owner'  THEN TRUE
            WHEN current_setting('app.current_realm', true) = 'work'   THEN realm IN ('work','shared')
            WHEN current_setting('app.current_realm', true) = 'family' THEN realm IN ('family','shared')
            WHEN current_setting('app.current_realm', true) IS NULL
              OR current_setting('app.current_realm', true) = ''        THEN TRUE
            ELSE FALSE
        END
    $expr$;
BEGIN
    FOR r IN
        SELECT col.table_name
          FROM information_schema.columns col
         WHERE col.table_schema = 'public'
           AND col.column_name = 'realm'
           AND col.table_name <> ALL (skip_partitions)
           AND NOT EXISTS (
               SELECT 1 FROM pg_policies p
                WHERE p.schemaname = 'public'
                  AND p.tablename  = col.table_name
           )
         ORDER BY col.table_name
    LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', r.table_name);
        EXECUTE format(
            'CREATE POLICY realm_isolation ON public.%I AS PERMISSIVE FOR ALL USING (%s)',
            r.table_name, realm_expr
        );
    END LOOP;
END
$body$;

-- -----------------------------------------------------------------------------
-- Verification — every realm-bearing public table (excluding partition
-- children) has at least one policy now.
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    missing_count INT;
    missing_tables TEXT;
    skip_partitions CONSTANT TEXT[] := ARRAY[
        'events_2026_04','events_2026_05','events_2026_06','events_2026_07',
        'events_overflow'
    ];
BEGIN
    SELECT COUNT(*), string_agg(table_name, ', ' ORDER BY table_name)
      INTO missing_count, missing_tables
      FROM (
        SELECT col.table_name
          FROM information_schema.columns col
         WHERE col.table_schema = 'public'
           AND col.column_name = 'realm'
           AND col.table_name <> ALL (skip_partitions)
           AND NOT EXISTS (
               SELECT 1 FROM pg_policies p
                WHERE p.schemaname = 'public'
                  AND p.tablename  = col.table_name
           )
      ) miss;

    IF missing_count > 0 THEN
        RAISE EXCEPTION 'V65b verification failed: % realm-bearing table(s) still without policy: %',
            missing_count, missing_tables;
    END IF;

    RAISE NOTICE 'V65b verification PASS: every realm-bearing public table (ex partitions) has a policy.';
END $$;

COMMIT;
