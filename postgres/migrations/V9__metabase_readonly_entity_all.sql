-- V9: let homeai_readonly see all entities by default in Metabase.
--
-- RLS policies on entity-scoped tables use:
--   CASE WHEN current_setting('app.current_entity', true) = 'all' THEN true
--        WHEN current_setting('app.current_entity', true) ~ '^\d+$' THEN entity_id = ...
--        ELSE false END
--
-- Pipeline writers (homeai_pipeline) set this explicitly per transaction via
-- SET LOCAL app.current_entity = '<n>'. Metabase connects as homeai_readonly
-- with no per-session setup, so the CASE falls through to false and every
-- query returns zero rows. Set 'all' as the per-database default for the
-- read-only role so cross-entity analytics works.
--
-- This is safe because:
--   1. homeai_readonly has only SELECT grants — it cannot mutate.
--   2. The 'all' token was already part of the policy expression by design.
--   3. ALTER ROLE ... IN DATABASE scopes only to homeai; the role's behaviour
--      in metabase_app (where it has no grants anyway) is unchanged.
--   4. Idempotent — ALTER ROLE SET overwrites any previous setting.

ALTER ROLE homeai_readonly IN DATABASE homeai
  SET app.current_entity = 'all';
