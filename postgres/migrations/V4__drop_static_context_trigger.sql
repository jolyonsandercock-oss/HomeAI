-- V4__drop_static_context_trigger.sql
-- Drops the AFTER UPDATE trigger on static_context (notify_context_change).
--
-- Why removed:
--   1. Blocked by RLS — events has relrowsecurity = t with no INSERT policy
--      for homeai_pipeline, so every UPDATE on static_context fails with
--      "new row violates row-level security policy for table events".
--   2. Violates HMAC signing rule — trigger writes payload_signature =
--      'init_placeholder', contradicting the non-negotiable rule that every
--      events row is HMAC-SHA256 signed (SPEC §2.2).
--
-- Replacement: services that mutate static_context emit a properly-signed
-- system.config_change event from application code (see model-evaluator
-- deploy_model).
--
-- Discovered: 2026-05-02 while running Step 9b acceptance gate.
--
-- Idempotent: safe to re-run. Apply:
--   docker exec -i homeai-postgres psql -U postgres -d homeai \
--     -f - < postgres/migrations/V4__drop_static_context_trigger.sql

\set ON_ERROR_STOP on

DROP TRIGGER IF EXISTS static_context_change ON static_context;
DROP FUNCTION IF EXISTS notify_context_change();
