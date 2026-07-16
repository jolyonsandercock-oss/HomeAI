-- V311 (2026-07-16) — escalation shadow study.
--
-- Purpose: decide, on REAL traffic, whether the local heavy model
-- (gemma4-qat31b) can absorb the cloud (Haiku) escalations instead of paying
-- for them. A 3-model bench (2026-07-16) showed gemma-qat31b far stronger than
-- the hot qwen on the tasks that dominate escalations (report parse 68% vs 31%,
-- JSON validity 100% vs 30%) but the historical escalated items were
-- unrecoverable (trace ids don't reach domain rows, confidence stored
-- post-escalation). So we capture escalations going forward: every time
-- llm-router escalates to cloud, it also runs gemma-qat31b on the SAME prompt
-- (fire-and-forget, never affecting the response) and logs all three answers
-- here. After ~2 weeks this table holds real hard cases with the cloud answer
-- as the ground-truth proxy, and we score gemma vs cloud to decide routing.
CREATE TABLE IF NOT EXISTS escalation_shadow (
  id                BIGSERIAL PRIMARY KEY,
  ts                TIMESTAMPTZ NOT NULL DEFAULT now(),
  trace_id          UUID,
  task_type         TEXT NOT NULL,
  primary_tier      TEXT,              -- tier that ran first (hot/medium)
  primary_model     TEXT,             -- e.g. qwen2.5:7b or gemma4:26b
  escalation_reason TEXT,             -- why it escalated (low conf / bad json / timeout)
  prompt_excerpt    TEXT,             -- first ~500 chars for context
  prompt_sha        TEXT,             -- full-prompt hash for dedup
  hot_text          TEXT,             -- the primary model's (rejected) answer
  cloud_model       TEXT,             -- the escalation target actually used
  cloud_text        TEXT,             -- the accepted answer = ground-truth proxy
  shadow_model      TEXT,             -- gemma4-qat31b:latest
  shadow_text       TEXT,             -- the local heavy model's answer
  shadow_latency_ms INTEGER,
  shadow_error      TEXT,             -- non-null if the shadow call failed
  realm             TEXT NOT NULL DEFAULT 'owner'
);
CREATE INDEX IF NOT EXISTS escalation_shadow_task_ts ON escalation_shadow (task_type, ts DESC);
GRANT SELECT ON escalation_shadow TO homeai_readonly;
GRANT INSERT ON escalation_shadow TO homeai_pipeline;
GRANT USAGE, SELECT ON SEQUENCE escalation_shadow_id_seq TO homeai_pipeline;
