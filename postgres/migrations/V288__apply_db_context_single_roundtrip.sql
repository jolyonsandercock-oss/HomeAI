-- V288 — home_ai.apply_db_context(): collapse the per-query context setup
-- (SET LOCAL ROLE + app.current_entity + home_ai.set_realm) from three
-- client round-trips into one (2026-07-03 perf pass).
--
-- Semantics preserved exactly, in guaranteed order:
--   1. role switch first (set_config('role', ..., true) === SET LOCAL ROLE),
--      so set_realm's role-realm pairing checks see the switched
--      current_user, same as the old statement sequence;
--   2. entity GUC (skipped when NULL — caller controls defaulting, matching
--      the old _apply_db_context branches);
--   3. home_ai.set_realm() last (SECURITY DEFINER, does its own validation).
--
-- SECURITY INVOKER: the role switch is only permitted if the session user
-- could SET ROLE anyway — no privilege change vs the old inline statements.

CREATE OR REPLACE FUNCTION home_ai.apply_db_context(
    p_role   text,
    p_entity text,
    p_realm  text
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_role IS NOT NULL THEN
        IF p_role !~ '^[A-Za-z_][A-Za-z0-9_]*$' THEN
            RAISE EXCEPTION 'apply_db_context: unsafe role name %', p_role
                USING ERRCODE = '22023';
        END IF;
        PERFORM set_config('role', p_role, true);
    END IF;
    IF p_entity IS NOT NULL THEN
        PERFORM set_config('app.current_entity', p_entity, true);
    END IF;
    PERFORM home_ai.set_realm(p_realm);
END
$$;

COMMENT ON FUNCTION home_ai.apply_db_context(text, text, text) IS
    'One-round-trip transaction context: optional SET LOCAL ROLE, optional app.current_entity, then set_realm. Used by build-dashboard db helpers (V288).';
