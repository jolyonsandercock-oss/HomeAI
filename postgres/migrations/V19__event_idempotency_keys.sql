-- V19: event_idempotency_keys dedup table.
--
-- Why this exists: a UNIQUE constraint on events.idempotency_key is
-- impossible without including the partition key (created_at) per
-- PostgreSQL's partitioned-table rules — and a UNIQUE on (idempotency_key,
-- created_at) defeats the purpose because two events with the same
-- idempotency_key but different timestamps would both succeed.
--
-- Workaround: a separate non-partitioned table whose ONLY job is to hold
-- idempotency_key as PRIMARY KEY. INSERT into events is gated by an
-- INSERT into this table first; ON CONFLICT DO NOTHING gives atomic dedup
-- without the WHERE NOT EXISTS race window.
--
-- Migration path:
--   1. Backfill from events (so existing keys are protected immediately)
--   2. Document the new pattern; existing pipelines stay on WHERE NOT EXISTS
--      (it works for our single-worker n8n setup) and migrate at next touch.
--
-- AGENTS.md memory rule about WHERE NOT EXISTS still applies — this table
-- is the *strict* path for new code; the WHERE NOT EXISTS pattern remains
-- an acceptable simpler alternative when concurrency is bounded.

\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS event_idempotency_keys (
  idempotency_key TEXT PRIMARY KEY,
  first_seen_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  first_event_id  BIGINT,
  source_pipeline TEXT
);

CREATE INDEX IF NOT EXISTS idx_eik_first_seen
  ON event_idempotency_keys (first_seen_at DESC);

GRANT SELECT, INSERT ON event_idempotency_keys TO homeai_pipeline;

-- Backfill from existing events
INSERT INTO event_idempotency_keys (idempotency_key, first_seen_at, first_event_id, source_pipeline)
SELECT idempotency_key, MIN(created_at), MIN(id), 'backfill_v19'
  FROM events
 WHERE idempotency_key IS NOT NULL
   AND idempotency_key <> ''
 GROUP BY idempotency_key
ON CONFLICT (idempotency_key) DO NOTHING;

-- Helper function: claim_idempotency_key(key, source_pipeline)
-- Returns true if this is the first claim, false if already claimed.
-- New code should call this before INSERT INTO events.
CREATE OR REPLACE FUNCTION claim_idempotency_key(p_key TEXT, p_source TEXT DEFAULT NULL)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $fn$
BEGIN
  INSERT INTO event_idempotency_keys (idempotency_key, source_pipeline)
  VALUES (p_key, p_source)
  ON CONFLICT (idempotency_key) DO NOTHING;
  RETURN FOUND;
END
$fn$;

GRANT EXECUTE ON FUNCTION claim_idempotency_key(TEXT, TEXT) TO homeai_pipeline;

SELECT 'event_idempotency_keys ready' AS check,
       count(*)::text || ' keys backfilled' AS detail
  FROM event_idempotency_keys;
