-- V13: archive historic dead_letter rows, fix recover_stale_leases bug.
--
-- Problems uncovered 2026-05-08 once postgres-exporter custom metrics surfaced
-- dead_letter at 10,948 rows growing by ~2k/hr:
--
-- 1. recover_stale_leases() dead-letters events with retry_count >= 3, but
--    never updates events.status away from 'processing'. So the same event
--    matches the dead-letter clause every Master Router cycle (every 30s)
--    and gets re-inserted. Result: one stuck event = unbounded dead_letter
--    growth. The `ON CONFLICT DO NOTHING` was meant to prevent this but the
--    table has no unique constraint, so the clause is a no-op.
--
-- 2. dead_letter has no UNIQUE on event_id — `ON CONFLICT DO NOTHING` against
--    no constraint silently does nothing.
--
-- 3. The 23 events currently in 'processing' are duplicate Gmail Trigger
--    events for the same gmail_message_id. The duplicate-event creation is
--    a separate bug in the Gmail Trigger workflow (to fix in B3 — P1
--    emitter wiring sprint). For now we mark them 'failed' so they leave
--    the queue.
--
-- This migration:
--   a) Archives all current dead_letter rows to dead_letter_archive.
--   b) Truncates dead_letter, leaves a marker row.
--   c) Adds UNIQUE constraint on dead_letter.event_id.
--   d) Marks the 23 stuck `processing` events as 'failed'.
--   e) Replaces recover_stale_leases() to update event status atomically
--      with the dead_letter INSERT.

\set ON_ERROR_STOP on

-- ─────────────────────────────────────────────────────────────────
-- a) Archive
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS dead_letter_archive (LIKE dead_letter INCLUDING ALL);

INSERT INTO dead_letter_archive
SELECT * FROM dead_letter
ON CONFLICT (id) DO NOTHING;

-- ─────────────────────────────────────────────────────────────────
-- b) Truncate + marker
-- ─────────────────────────────────────────────────────────────────
TRUNCATE dead_letter RESTART IDENTITY;

INSERT INTO dead_letter (event_id, pipeline, error_message, retry_count, resolved, resolution_notes, created_at)
VALUES (NULL, 'system_marker',
        'V13 cleanup 2026-05-08 — archived prior rows to dead_letter_archive (10,948 rows from recover_stale_leases bug). Forward-going alerts now meaningful.',
        0, true, 'historic noise — see dead_letter_archive', NOW());

-- ─────────────────────────────────────────────────────────────────
-- c) UNIQUE constraint on event_id (so ON CONFLICT actually works)
--    NULL event_ids (like the marker above) are permitted multiple
--    times because Postgres treats NULLs as distinct in UNIQUE indexes.
-- ─────────────────────────────────────────────────────────────────
ALTER TABLE dead_letter
  ADD CONSTRAINT dead_letter_event_id_uq UNIQUE (event_id);

-- ─────────────────────────────────────────────────────────────────
-- d) Mark the 23 stuck `processing` events as 'failed'
-- ─────────────────────────────────────────────────────────────────
UPDATE events
   SET status        = 'failed',
       error_message = 'Marked failed during V13 cleanup — recover_stale_leases bug + duplicate Gmail Trigger events. See dead_letter_archive.',
       processed_at  = NOW()
 WHERE status = 'processing'
   AND retry_count >= 3;

-- ─────────────────────────────────────────────────────────────────
-- e) Fixed recover_stale_leases — atomically updates event.status
--    when dead-lettering, so the same event isn't redead-lettered.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION recover_stale_leases()
RETURNS TABLE(recovered_count BIGINT, dead_lettered_count BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_recovered  BIGINT;
  v_dead_let   BIGINT;
BEGIN
  -- Recover events whose lease has expired and still have retries left
  WITH recovered AS (
    UPDATE events
       SET status                = 'pending',
           processing_started_at = NULL,
           processing_node_id    = NULL,
           retry_count           = retry_count + 1
     WHERE status = 'processing'
       AND processing_started_at < NOW() - INTERVAL '10 minutes'
       AND retry_count < 3
    RETURNING id
  )
  SELECT count(*) INTO v_recovered FROM recovered;

  -- Dead-letter events past retry limit AND mark them terminal in events.
  -- Single CTE chain keeps the two writes atomic — no race where the
  -- dead-letter row exists but the event is still 'processing'.
  WITH stuck AS (
    SELECT e.id, e.retry_count, e.processing_node_id
      FROM events e
     WHERE e.status = 'processing'
       AND e.processing_started_at < NOW() - INTERVAL '10 minutes'
       AND e.retry_count >= 3
       FOR UPDATE OF e SKIP LOCKED
  ),
  inserted AS (
    INSERT INTO dead_letter (event_id, pipeline, error_message, retry_count)
    SELECT s.id,
           'stale_lease_recovery',
           'Max retries exceeded — stale on node ' || COALESCE(s.processing_node_id, 'unknown'),
           s.retry_count
      FROM stuck s
    ON CONFLICT (event_id) DO NOTHING
    RETURNING event_id
  ),
  finalised AS (
    UPDATE events e
       SET status        = 'failed',
           processed_at  = NOW(),
           error_message = COALESCE(e.error_message, 'Stale lease — exceeded retry limit')
     WHERE e.id IN (SELECT id FROM stuck)
    RETURNING e.id
  )
  SELECT count(*) INTO v_dead_let FROM finalised;

  recovered_count     := v_recovered;
  dead_lettered_count := v_dead_let;
  RETURN NEXT;
END;
$fn$;

GRANT EXECUTE ON FUNCTION recover_stale_leases() TO homeai_pipeline;

-- ─────────────────────────────────────────────────────────────────
-- Verification
-- ─────────────────────────────────────────────────────────────────
SELECT 'dead_letter rows after cleanup' AS check, count(*)::text AS value FROM dead_letter
UNION ALL
SELECT 'dead_letter_archive rows', count(*)::text FROM dead_letter_archive
UNION ALL
SELECT 'events stuck >10m in processing', count(*)::text
  FROM events
 WHERE status = 'processing' AND processing_started_at < NOW() - INTERVAL '10 minutes'
UNION ALL
SELECT 'events newly failed', count(*)::text
  FROM events WHERE status = 'failed';
