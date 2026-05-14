-- =============================================================================
-- V65 — Realm RLS enforcement, phase 1 (R2)
-- =============================================================================
-- Layers a RESTRICTIVE `realm_isolation` policy onto every table that already
-- has a permissive entity-level policy (entity_isolation, accommodation_*_rls,
-- epos_daily_rls). The new policy AND-composes with the existing one so the
-- behaviour is: a row is visible iff the entity policy admits it AND the
-- realm policy admits it.
--
-- Behaviour matrix for app.current_realm:
--
--   value       | policy result
--   ------------|--------------------------------------------------------------
--   'owner'     | TRUE for every row (OWNER realm sees everything)
--   'work'      | realm IN ('work','shared')
--   'family'    | realm IN ('family','shared')
--   NULL/empty  | TRUE — transitional pass-through; behaviour identical to
--               | pre-V65. Used while services are still being taught to set
--               | app.current_realm per request. Flip lever is the
--               | REALM_ENFORCE env var on each service (U52 T5).
--   any other   | FALSE — fail-closed for an unrecognised value.
--
-- The CASE expression follows the V5 idiom (avoids PG's eager cast on the
-- type-mismatch path that bit us with app.current_entity = 'all').
--
-- Notes for future maintainers:
--   * RLS combines multiple PERMISSIVE policies with OR. Two PERMISSIVE
--     filters (one for entity, one for realm) would WIDEN, not narrow. We
--     therefore mark realm_isolation as RESTRICTIVE so PG combines with AND.
--   * home_ai.set_realm(text) is the single chokepoint. Services should
--     prefer SELECT home_ai.set_realm(...) over SET LOCAL so the validation
--     check runs and an out-of-domain value fails fast instead of silently
--     hitting the fail-closed branch.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Step 1: home_ai.set_realm chokepoint function.
-- -----------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS home_ai;
GRANT USAGE ON SCHEMA home_ai TO PUBLIC;

CREATE OR REPLACE FUNCTION home_ai.set_realm(p_realm TEXT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_realm IS NULL OR p_realm = '' THEN
        -- Permitted: transitional unset state.
        PERFORM set_config('app.current_realm', '', true);
        RETURN '';
    END IF;

    IF p_realm NOT IN ('owner','work','family') THEN
        RAISE EXCEPTION 'home_ai.set_realm: invalid realm %, expected one of (owner, work, family)', p_realm
            USING ERRCODE = '22023';  -- invalid_parameter_value
    END IF;

    PERFORM set_config('app.current_realm', p_realm, true);
    RETURN p_realm;
END
$$;

COMMENT ON FUNCTION home_ai.set_realm(TEXT) IS
    'R2 chokepoint: validate and set app.current_realm for the current '
    'transaction. Use this instead of raw SET LOCAL so unrecognised values '
    'fail fast.';

GRANT EXECUTE ON FUNCTION home_ai.set_realm(TEXT) TO PUBLIC;

-- -----------------------------------------------------------------------------
-- Step 2: Apply RESTRICTIVE realm_isolation policy to every table that
-- already has a permissive entity-level policy.
-- -----------------------------------------------------------------------------

DO $body$
DECLARE
    r RECORD;
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
        SELECT DISTINCT tablename
          FROM pg_policies
         WHERE schemaname = 'public'
         ORDER BY tablename
    LOOP
        -- Skip if a realm_isolation policy already exists (idempotent re-run).
        IF EXISTS (
            SELECT 1 FROM pg_policies
             WHERE schemaname = 'public'
               AND tablename = r.tablename
               AND policyname = 'realm_isolation'
        ) THEN
            CONTINUE;
        END IF;

        -- Sanity: the table must actually have a realm column. Anything
        -- else is a V64 gap that should be fixed there, not here.
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name = r.tablename
               AND column_name = 'realm'
        ) THEN
            RAISE NOTICE 'V65 skip: %.realm column missing (V64 gap, not V65 concern)', r.tablename;
            CONTINUE;
        END IF;

        EXECUTE format(
            'CREATE POLICY realm_isolation ON public.%I AS RESTRICTIVE FOR ALL USING (%s)',
            r.tablename, realm_expr
        );
    END LOOP;
END
$body$;

-- -----------------------------------------------------------------------------
-- Step 3: Verification — every entity-policied table now also has
-- realm_isolation, AND that policy is RESTRICTIVE (not PERMISSIVE — would
-- silently change behaviour).
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    missing_count INT;
    wrong_kind_count INT;
    missing_tables TEXT;
BEGIN
    -- Tables that have *some* policy but lack realm_isolation.
    SELECT COUNT(*), string_agg(tablename, ', ' ORDER BY tablename)
      INTO missing_count, missing_tables
      FROM (
        SELECT DISTINCT tablename
          FROM pg_policies p1
         WHERE schemaname = 'public'
           AND NOT EXISTS (
               SELECT 1 FROM pg_policies p2
                WHERE p2.schemaname = 'public'
                  AND p2.tablename  = p1.tablename
                  AND p2.policyname = 'realm_isolation'
           )
      ) miss;

    IF missing_count > 0 THEN
        RAISE EXCEPTION 'V65 verification failed: % table(s) without realm_isolation: %',
            missing_count, missing_tables;
    END IF;

    -- realm_isolation must be RESTRICTIVE, not PERMISSIVE.
    SELECT COUNT(*) INTO wrong_kind_count
      FROM pg_policies
     WHERE schemaname = 'public'
       AND policyname = 'realm_isolation'
       AND permissive <> 'RESTRICTIVE';

    IF wrong_kind_count > 0 THEN
        RAISE EXCEPTION 'V65 verification failed: % realm_isolation policy(s) are PERMISSIVE (must be RESTRICTIVE)',
            wrong_kind_count;
    END IF;

    RAISE NOTICE 'V65 verification PASS: realm_isolation RESTRICTIVE policy on every entity-policied table.';
END $$;

COMMIT;
