-- V18: model_usage_history table — dual-stream lineage logging.
--
-- Distinguishes "Build Layer" (Claude Code building this system) from
-- "Production Layer" (n8n pipelines running daily ops). Both share the same
-- observability stream so the dashboard can show a true total-lifecycle view.
--
-- Columns:
--   context_layer  — 'build' or 'production'
--   tier           — 'apex' | 'legacy_apex' | 'local_logic' | 'cloud_speed' | 'local_fast' | 'manual'
--   actor          — who/what initiated (e.g. 'claude_code', 'invoice-pipeline-v1', 'jo')
--   model          — fully qualified model name
--   task_summary   — short human-readable description
--   tokens_in / tokens_out  — when known
--   cost_gbp       — computed cost (£) or 0 for local
--   provider       — 'anthropic' | 'local' | 'manual'
--   trace_id       — link back to events / audit_log when available
--
-- Migration log entries (model swaps, tier reassignments) get logged here too
-- with task_summary='migration:<from>→<to>' and provider='manual'.

\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS model_usage_history (
  id              BIGSERIAL PRIMARY KEY,
  ts              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  context_layer   TEXT NOT NULL CHECK (context_layer IN ('build','production','migration')),
  tier            TEXT,
  actor           TEXT NOT NULL,
  model           TEXT NOT NULL,
  provider        TEXT,
  task_summary    TEXT,
  tokens_in       INT DEFAULT 0,
  tokens_out      INT DEFAULT 0,
  cost_gbp        NUMERIC(10,6) DEFAULT 0,
  trace_id        UUID,
  metadata        JSONB
);

CREATE INDEX IF NOT EXISTS idx_muh_layer_ts
  ON model_usage_history (context_layer, ts DESC);
CREATE INDEX IF NOT EXISTS idx_muh_actor_ts
  ON model_usage_history (actor, ts DESC);
CREATE INDEX IF NOT EXISTS idx_muh_model_ts
  ON model_usage_history (model, ts DESC);

GRANT INSERT, SELECT ON model_usage_history TO homeai_pipeline;
GRANT USAGE ON SEQUENCE model_usage_history_id_seq TO homeai_pipeline;
GRANT SELECT ON model_usage_history TO homeai_readonly;

-- ─────────────────────────────────────────────────────────────────
-- Update static_context.model.tiers to the 5-tier hierarchy.
-- The existing 'hot/medium/heavy' keys are kept for backward compat with
-- workflows that still read them; the new 'tiers_v2' key is the canonical
-- 5-tier map that the dashboard + Master Router consult going forward.
-- ─────────────────────────────────────────────────────────────────
INSERT INTO static_context (key, entity_id, value)
VALUES ('model.tiers_v2', NULL, '{
  "apex": {
    "model": "claude-opus-4-7",
    "provider": "anthropic",
    "use_for": "multi-file code surgery, architectural pivots"
  },
  "legacy_apex": {
    "model": "claude-opus-4-6",
    "provider": "anthropic",
    "use_for": "long-context dreaming, deep research"
  },
  "local_logic": {
    "model": "phi4:14b",
    "provider": "local",
    "use_for": "complex JSON/logic, private docs, medium-tier extraction"
  },
  "cloud_speed": {
    "model": "claude-haiku-4-5-20251001",
    "provider": "anthropic",
    "use_for": "fast triage, high-volume API glue, escalation"
  },
  "local_fast": {
    "model": "qwen2.5:7b",
    "provider": "local",
    "use_for": "log parsing, basic summaries, hot dashboard refreshes"
  }
}'::jsonb)
ON CONFLICT (key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

-- Backfill: capture every audit_log row that already involved an AI model
-- as a 'production' layer entry. This gives the dashboard immediate data
-- to render rather than starting from zero.
INSERT INTO model_usage_history
  (ts, context_layer, tier, actor, model, provider, task_summary,
   tokens_in, tokens_out, trace_id)
SELECT
  a.created_at,
  'production',
  CASE
    WHEN a.ai_model LIKE 'claude-opus-%'      THEN 'apex'
    WHEN a.ai_model LIKE 'claude-sonnet-%'    THEN 'cloud_speed'  -- close enough
    WHEN a.ai_model LIKE 'claude-haiku-%'     THEN 'cloud_speed'
    WHEN a.ai_model LIKE 'phi4%'              THEN 'local_logic'
    WHEN a.ai_model LIKE 'qwen%' OR a.ai_model LIKE 'llama%' OR a.ai_model LIKE 'mistral%'
                                              THEN 'local_fast'
    ELSE 'manual'
  END,
  COALESCE(a.pipeline, 'unknown'),
  COALESCE(a.ai_model, 'n/a'),
  a.provider,
  COALESCE(a.action, 'audit_log_backfill'),
  0, 0,
  a.trace_id
FROM audit_log a
WHERE a.ai_model IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM model_usage_history m
     WHERE m.actor = a.pipeline
       AND m.task_summary = a.action
       AND m.ts = a.created_at
  );

SELECT 'model_usage_history rows after backfill' AS check, count(*)::text AS value FROM model_usage_history;
