-- V17: add provider column to audit_log + ai_usage so the dashboard can
-- compute Sovereignty Score (local-vs-cloud split) without parsing model
-- name strings at query time.
--
-- Provider taxonomy:
--   local      → Ollama-hosted model
--   anthropic  → Anthropic Cloud (Haiku, Sonnet, Opus)
--   n/a        → no AI involved (deterministic pipelines like cleanup, partition_maintenance)

\set ON_ERROR_STOP on

-- audit_log
ALTER TABLE audit_log
  ADD COLUMN IF NOT EXISTS provider TEXT;

CREATE INDEX IF NOT EXISTS idx_audit_provider
  ON audit_log (provider, created_at DESC)
  WHERE provider IS NOT NULL;

-- ai_usage already has model_used; add provider for query-time cheapness.
ALTER TABLE ai_usage
  ADD COLUMN IF NOT EXISTS provider TEXT;

CREATE INDEX IF NOT EXISTS idx_ai_usage_provider
  ON ai_usage (provider, "timestamp" DESC)
  WHERE provider IS NOT NULL;

-- Backfill existing rows. Heuristic: model name string.
--  - Anything with 'claude-' prefix → anthropic
--  - Anything matching qwen / phi / llama / mistral / gemma → local
--  - Otherwise NULL (will be filled going forward by workflow patches)
UPDATE audit_log
   SET provider = CASE
     WHEN ai_model LIKE 'claude-%'                                        THEN 'anthropic'
     WHEN ai_model ~* '^(qwen|phi|llama|mistral|gemma|deepseek|granite)'  THEN 'local'
     WHEN ai_worker IS NULL                                               THEN 'n/a'
     ELSE provider
   END
 WHERE provider IS NULL;

UPDATE ai_usage
   SET provider = CASE
     WHEN model_used LIKE 'claude-%'                                       THEN 'anthropic'
     WHEN model_used ~* '^(qwen|phi|llama|mistral|gemma|deepseek|granite)' THEN 'local'
     ELSE provider
   END
 WHERE provider IS NULL;

SELECT 'audit_log provider backfill summary' AS check,
       provider,
       count(*)
  FROM audit_log
 GROUP BY provider
 ORDER BY count(*) DESC;
