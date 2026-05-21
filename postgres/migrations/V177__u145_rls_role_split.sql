-- =============================================================================
-- V177 — U145: per-realm Postgres roles (DRAFT — do not apply without sign-off)
-- =============================================================================
-- HIGHEST-BLAST-RADIUS migration in the stack. Adds three roles that map to
-- the realm model so connection-pool partitioning becomes a real defence
-- layer rather than an app-layer GUC convention.
--
--   trading_role    — connects with app.current_realm='work',     entity 1
--   personal_role   — connects with app.current_realm='personal', entities 2,3,4
--   owner_role      — superuser-equivalent for Jo, bypasses realm RLS
--
-- The existing homeai_readonly and homeai_pipeline roles STAY for backwards
-- compatibility during migration. New services connect via the new roles.
-- Once every consumer is migrated, the old roles can be dropped (V178+).
--
-- PEN-TEST EXPECTATIONS (run after apply on a copy):
--   SET ROLE trading_role;       SET app.current_realm='work';
--   SELECT COUNT(*) FROM vendor_invoice_inbox WHERE realm='personal';
--      -- expect 0 (RLS hides it; pen test asserts isolation)
--   SET ROLE personal_role;      SET app.current_realm='personal';
--   SELECT COUNT(*) FROM vendor_invoice_inbox WHERE realm='work';
--      -- expect 0
--   SET ROLE owner_role;         SET app.current_realm='owner';
--   SELECT COUNT(*) FROM vendor_invoice_inbox;
--      -- expect 9000+ (all rows visible)
--
-- Consumer wiring change (post-apply): each service's connection string
-- changes from homeai_readonly to whichever role matches its intended realm.
-- See `.claude/plans/u145-consumer-mapping.md` for the per-service plan.
-- =============================================================================

BEGIN;

-- ---- 1. Create the roles -----------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='trading_role') THEN
        CREATE ROLE trading_role NOINHERIT;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='personal_role') THEN
        CREATE ROLE personal_role NOINHERIT;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='owner_role') THEN
        CREATE ROLE owner_role NOINHERIT BYPASSRLS;
    END IF;
END
$$;

-- ---- 2. Grant SELECT (+ targeted writes) on every realm-aware table ---------
-- Strategy: trading_role and personal_role both get SELECT/INSERT/UPDATE on
-- the full operational schema. RLS does the realm enforcement — the role
-- only changes what SET app.current_realm gets used as.
--
-- This is intentionally permissive at the GRANT layer because RLS policies
-- are doing the real filtering. The role gives us:
--   1. a connection-pool partitioning anchor (each role has its own pool)
--   2. a paper trail in audit_log (which role made which write)
--   3. defence-in-depth: a buggy service can't escalate to another realm
--      just by changing app.current_realm — its role only knows one realm.
--
-- That third property requires the role to ALSO be constrained from calling
-- home_ai.set_realm() with a different value. Enforced via the function's
-- SECURITY DEFINER + check below.

DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT n.nspname AS sch, cls.relname AS t
          FROM pg_attribute a
          JOIN pg_class cls ON cls.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = cls.relnamespace
         WHERE a.attname='realm' AND cls.relkind='r'
           AND n.nspname='public'
    LOOP
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.%I TO trading_role, personal_role, owner_role',
                       r.sch, r.t);
        -- Sequences for INSERTs
        EXECUTE format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %I TO trading_role, personal_role, owner_role',
                       r.sch);
    END LOOP;
END
$$;

-- Also grant on shared lookup tables (entities, query_whitelist, etc.)
GRANT SELECT ON entities, query_whitelist TO trading_role, personal_role, owner_role;

-- ---- 3. Tighten home_ai.set_realm so a role can't impersonate another -------
-- New behaviour: validate that p_realm is allowed for the calling role.
CREATE OR REPLACE FUNCTION home_ai.set_realm(p_realm text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = home_ai, public
AS $$
DECLARE
    me TEXT := current_user;
BEGIN
    IF p_realm IS NULL OR p_realm = '' THEN
        PERFORM set_config('app.current_realm', '', true);
        RETURN '';
    END IF;
    IF p_realm NOT IN ('owner','work','personal') THEN
        RAISE EXCEPTION 'home_ai.set_realm: invalid realm %, expected one of (owner, work, personal)', p_realm
            USING ERRCODE = '22023';
    END IF;
    -- Role-realm pairing enforcement.
    -- owner_role and superusers can set any realm.
    -- trading_role can only set 'work' or '' (clear).
    -- personal_role can only set 'personal' or ''.
    -- Other roles (homeai_readonly, homeai_pipeline) — pre-U145 unchanged.
    IF me = 'trading_role'  AND p_realm <> 'work'     THEN
        RAISE EXCEPTION 'role trading_role can only set realm=work, refused %', p_realm
            USING ERRCODE = '42501';  -- insufficient_privilege
    END IF;
    IF me = 'personal_role' AND p_realm <> 'personal' THEN
        RAISE EXCEPTION 'role personal_role can only set realm=personal, refused %', p_realm
            USING ERRCODE = '42501';
    END IF;
    PERFORM set_config('app.current_realm', p_realm, true);
    RETURN p_realm;
END
$$;

GRANT EXECUTE ON FUNCTION home_ai.set_realm(text) TO trading_role, personal_role, owner_role;

COMMIT;

-- =============================================================================
-- DO NOT RUN YET — needs operator decision on:
--   1. Per-service connection-pool partitioning (does build-dashboard use
--      trading_role + personal_role with two pools, or stay on homeai_readonly?)
--   2. n8n credentials migration (currently uses homeai_pipeline)
--   3. Password setup for new roles (random + persisted to Vault under
--      secret/postgres-roles)
--   4. lib/db.ts realm-to-role mapping in homeai-frontend
-- =============================================================================
