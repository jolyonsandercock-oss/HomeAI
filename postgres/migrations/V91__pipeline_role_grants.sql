-- =============================================================================
-- V91 — homeai_pipeline role grants on mart/raw/staging (U71 T4)
-- =============================================================================
-- Today AI services (build-dashboard, bot-responder, critical-listener) all
-- connect as the postgres superuser — which means RLS is bypassed and grant
-- discipline is meaningless. T4 prepares the runway to switch to the
-- least-privileged homeai_pipeline role.
--
-- This migration grants READ on the three "machine-built" schemas (mart, raw,
-- staging) because homeai_pipeline already has the necessary public-schema
-- grants. Writes to those schemas stay routed through SECURITY DEFINER
-- functions (mart.refresh_*, raw.touchoffice_ingest_*) so the role doesn't
-- need INSERT/UPDATE/DELETE there.
--
-- This migration does NOT flip the live DSN — that's a per-service cutover
-- that needs RLS GUC propagation testing. Switching is done by updating the
-- service env var to use the homeai_pipeline credentials from
-- secret/postgres-roles.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

-- USAGE on the schemas themselves.
GRANT USAGE ON SCHEMA mart, raw, staging TO homeai_pipeline;

-- SELECT on every current + future table/view in each schema.
GRANT SELECT ON ALL TABLES    IN SCHEMA mart    TO homeai_pipeline;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA mart    TO homeai_pipeline;
GRANT SELECT ON ALL TABLES    IN SCHEMA raw     TO homeai_pipeline;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA raw     TO homeai_pipeline;
GRANT SELECT ON ALL TABLES    IN SCHEMA staging TO homeai_pipeline;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA staging TO homeai_pipeline;

ALTER DEFAULT PRIVILEGES IN SCHEMA mart
    GRANT SELECT ON TABLES TO homeai_pipeline;
ALTER DEFAULT PRIVILEGES IN SCHEMA raw
    GRANT SELECT ON TABLES TO homeai_pipeline;
ALTER DEFAULT PRIVILEGES IN SCHEMA staging
    GRANT SELECT ON TABLES TO homeai_pipeline;

-- EXECUTE on SECURITY DEFINER refresh functions so a non-superuser caller
-- can still trigger the materialisation paths.
GRANT EXECUTE ON FUNCTION mart.refresh_cash_variance_day(integer) TO homeai_pipeline;

-- Tables added after the initial bootstrap-grant pass — fill the gap.
GRANT SELECT, INSERT, UPDATE ON
    recipes, recipe_components, product_canonical, product_alias, product_aliases
    TO homeai_pipeline;
GRANT USAGE, SELECT ON
    recipes_id_seq, recipe_components_id_seq, product_canonical_id_seq
    TO homeai_pipeline;

COMMIT;
