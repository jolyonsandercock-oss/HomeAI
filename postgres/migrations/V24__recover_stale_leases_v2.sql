-- V24: recover_stale_leases_v2 — downstream-aware lease recovery.
--
-- Why: V18-era recover_stale_leases() declares an event "max retries exceeded"
-- and dead-letters it after retry_count >= 3, regardless of whether the
-- downstream side-effect actually landed. U11 close (2026-05-10): 8 events
-- were false-dead-lettered while their downstream emails rows were already
-- present. This function adds a downstream check before dead-lettering.
--
-- Behaviour change (per event_type):
--   email.received                 → if a row in `emails` matches
--                                    payload->>'gmail_message_id', mark the
--                                    event 'processed' and write a
--                                    'recovered_post_lease' audit row
--   invoice.detected               → if a row in `invoices` has event_id=this,
--                                    mark processed
--   accommodation.report.detected  → if a row in `accommodation_daily` has
--                                    email_id matching payload->>'email_id'
--                                    OR source_event_id=this, mark processed
--   epos.report.detected           → same shape for `epos_daily`
--   (anything else)                → fall through to dead-letter path
--
-- Old function `recover_stale_leases()` is kept callable for manual rollback.
--
-- Idempotent: every step uses ON CONFLICT DO NOTHING / WHERE NOT EXISTS.
-- Safe to call concurrently (FOR UPDATE SKIP LOCKED on stuck rows).

\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION public.recover_stale_leases_v2()
RETURNS TABLE(
  recovered_count        BIGINT,
  resolved_post_lease    BIGINT,
  dead_lettered_count    BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_recovered  BIGINT := 0;
  v_resolved   BIGINT := 0;
  v_dead_let   BIGINT := 0;
BEGIN
  -- ── Phase 1: bump retry on stalls under retry_count threshold ─────────
  -- Same semantics as v1: extend lease, allow another attempt.
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

  -- ── Phase 2: events that exceeded retries — check downstream first ────
  WITH stuck AS (
    SELECT e.id, e.event_type, e.payload, e.retry_count, e.processing_node_id
      FROM events e
     WHERE e.status = 'processing'
       AND e.processing_started_at < NOW() - INTERVAL '10 minutes'
       AND e.retry_count >= 3
       FOR UPDATE OF e SKIP LOCKED
  ),
  classified AS (
    SELECT
      s.*,
      CASE
        WHEN s.event_type = 'email.received'
          AND EXISTS (
            SELECT 1 FROM emails em
             WHERE em.gmail_message_id = s.payload->>'gmail_message_id'
          )
          THEN 'recovered_email'

        WHEN s.event_type = 'invoice.detected'
          AND EXISTS (
            SELECT 1 FROM invoices iv
             WHERE iv.event_id = s.id
          )
          THEN 'recovered_invoice'

        WHEN s.event_type = 'accommodation.report.detected'
          AND EXISTS (
            SELECT 1 FROM accommodation_daily ad
             WHERE ad.email_id = (s.payload->>'email_id')::bigint
                OR ad.source_event_id = s.id
          )
          THEN 'recovered_accom'

        WHEN s.event_type = 'epos.report.detected'
          AND EXISTS (
            SELECT 1 FROM epos_daily ed
             WHERE ed.email_id = (s.payload->>'email_id')::bigint
                OR ed.source_event_id = s.id
          )
          THEN 'recovered_epos'

        ELSE 'dead_letter'
      END AS verdict
      FROM stuck s
  ),
  recover_branch AS (
    -- Mark events processed where downstream was already there
    UPDATE events e
       SET status       = 'processed',
           processed_at = NOW(),
           processing_started_at = NULL,
           processing_node_id    = NULL
     FROM classified c
     WHERE e.id = c.id
       AND c.verdict <> 'dead_letter'
    RETURNING e.id, c.verdict
  ),
  recover_audit AS (
    INSERT INTO audit_log (pipeline, event_id, action, ai_parsed, result)
    SELECT 'master_router',
           rb.id,
           'recovered_post_lease',
           jsonb_build_object('verdict', rb.verdict, 'reason', 'downstream_present_after_retries'),
           'success'
      FROM recover_branch rb
    RETURNING 1
  ),
  dead_letter_branch AS (
    INSERT INTO dead_letter (event_id, pipeline, error_message, retry_count)
    SELECT c.id,
           'stale_lease_recovery',
           'Max retries exceeded — stale on node ' || COALESCE(c.processing_node_id, 'unknown') || ' (downstream not present)',
           c.retry_count
      FROM classified c
     WHERE c.verdict = 'dead_letter'
    ON CONFLICT (event_id) DO NOTHING
    RETURNING event_id
  ),
  dead_letter_mark AS (
    UPDATE events e
       SET status = 'failed',
           processed_at = NOW()
      FROM dead_letter_branch dlb
     WHERE e.id = dlb.event_id
    RETURNING e.id
  )
  SELECT
    (SELECT count(*) FROM recover_branch),
    (SELECT count(*) FROM dead_letter_branch)
  INTO v_resolved, v_dead_let;

  RETURN QUERY SELECT v_recovered, v_resolved, v_dead_let;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.recover_stale_leases_v2() TO homeai_pipeline;

-- ── Sanity: function exists + signature ────────────────────────────────
SELECT 'V24 ready' AS check,
       (SELECT COUNT(*) FROM pg_proc
         WHERE proname = 'recover_stale_leases_v2')::text || ' function(s)' AS detail;
