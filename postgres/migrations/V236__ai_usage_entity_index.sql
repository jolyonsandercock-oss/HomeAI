-- V236 — A2 (from the #260 system review) resolved with judgement, not blanket indexing.
--
-- The review flagged "missing indexes causing full table scans" on entities, ai_usage,
-- static_context, quota_allocations, chat_hub_messages. Re-checked against live row
-- counts: entities=4, quota_allocations=4, static_context=23, chat_hub_messages=0.
-- Those are TINY tables — Postgres correctly seq-scans them (an index would never be
-- used and just adds write overhead). The high seq_scan *counts* reflect frequent reads
-- (RLS realm checks, the 30s kill-switch poll on static_context), not slow scans.
--
-- The only table with real size + growth is ai_usage (2,234 rows and climbing, one row
-- per AI call), and budget/quota enforcement filters it by entity_id over a time window.
-- That single index is justified; the rest are deliberately skipped.
BEGIN;

CREATE INDEX IF NOT EXISTS idx_ai_usage_entity_time
  ON public.ai_usage (entity_id, "timestamp" DESC);

COMMIT;
