-- V6__ai_usage.sql
-- Telemetry table for llm-router. Captures every routing decision (success
-- and error paths). Idempotent — safe to re-run.

CREATE TABLE IF NOT EXISTS ai_usage (
  id                BIGSERIAL PRIMARY KEY,
  timestamp         TIMESTAMPTZ DEFAULT NOW(),
  trace_id          UUID,
  entity_id         INT REFERENCES entities(id),
  task_type         TEXT NOT NULL,
  model_used        TEXT NOT NULL,
  tier              TEXT NOT NULL,
  escalated         BOOLEAN DEFAULT FALSE,
  escalation_reason TEXT,
  prompt_tokens     INT DEFAULT 0,
  completion_tokens INT DEFAULT 0,
  latency_ms        INT DEFAULT 0,
  cached            BOOLEAN DEFAULT FALSE
);

CREATE INDEX IF NOT EXISTS idx_ai_usage_task_type ON ai_usage (task_type, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_ai_usage_escalated ON ai_usage (escalated, timestamp DESC);

-- Grants. Required because rls-policies.sql's `GRANT ON ALL TABLES` only
-- applies to tables that existed at the time it ran. Tables created in later
-- migrations need explicit grants. Same pattern applies to any future
-- migration that creates a table.
GRANT SELECT, INSERT, UPDATE ON ai_usage TO homeai_pipeline;
GRANT USAGE, SELECT ON SEQUENCE ai_usage_id_seq TO homeai_pipeline;
GRANT SELECT ON ai_usage TO homeai_readonly;
