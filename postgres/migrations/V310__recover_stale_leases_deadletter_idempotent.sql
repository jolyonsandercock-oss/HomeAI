-- V310 (2026-07-16) — fix recover_stale_leases_v3 dead-letter idempotency bug.
--
-- Bug found 2026-07-16: 4 invoice.detected events (ids 68867, 70008, 70012,
-- 70017) sat in status='processing' for 24h+, tripping the "stuck processing
-- leases" selftest every 10 min and holding supervisor + hermes_sentinel at
-- rc=1 continuously since 07-15.
--
-- Root cause: the v3 function's dead-letter branch inserts into dead_letter
-- with `ON CONFLICT (event_id) DO NOTHING RETURNING event_id`, then the
-- dead_letter_mark CTE marks events 'failed' ONLY for the rows the insert
-- returned. If an event was ALREADY dead-lettered on a prior run (retry
-- exhausted, re-classified dead_letter again), the insert conflicts and
-- returns nothing, so the event is never moved out of 'processing' — it flaps
-- the selftest forever. The events WERE correctly in dead_letter; only the
-- events.status transition was skipped.
--
-- Fix: mark events 'failed' for ALL classified dead_letter verdicts (join on
-- `classified`, not on the insert's RETURNING set). Idempotent — an event
-- already 'failed' is a no-op. Everything else is byte-for-byte V186's v3.
CREATE OR REPLACE FUNCTION public.recover_stale_leases_v3()
RETURNS TABLE(recovered_count BIGINT, soft_recovered BIGINT, dead_lettered BIGINT)
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_recovered  BIGINT := 0;
  v_soft       BIGINT := 0;
  v_dead       BIGINT := 0;
BEGIN
  -- Phase 1 (unchanged): bump retry on stalls under threshold
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

  -- Phase 2: retry-exhausted events
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
          AND EXISTS (SELECT 1 FROM emails em WHERE em.gmail_message_id = s.payload->>'gmail_message_id')
          THEN 'recovered_email'
        WHEN s.event_type = 'invoice.detected'
          AND EXISTS (SELECT 1 FROM invoices iv WHERE iv.event_id = s.id)
          THEN 'recovered_invoice'
        WHEN s.event_type = 'accommodation.report.detected'
          AND EXISTS (SELECT 1 FROM accommodation_daily ad
                       WHERE ad.email_id = (s.payload->>'email_id')::bigint OR ad.source_event_id = s.id)
          THEN 'recovered_accom'
        WHEN s.event_type = 'epos.report.detected'
          AND EXISTS (SELECT 1 FROM epos_daily ed
                       WHERE ed.email_id = (s.payload->>'email_id')::bigint OR ed.source_event_id = s.id)
          THEN 'recovered_epos'
        WHEN s.event_type = 'document.received'
          AND (s.payload->>'mime_type') IS NOT NULL
          AND (s.payload->>'mime_type') <> 'application/pdf'
          THEN 'soft_recovered_nonpdf_doc'
        WHEN s.event_type = 'child.event.detected'
          AND s.retry_count >= 3
          THEN 'soft_recovered_nanny'
        WHEN s.event_type = 'invoice.detected'
          AND s.retry_count >= 3
          AND NOT EXISTS (SELECT 1 FROM email_attachments ea
                          WHERE ea.event_id = s.id OR
                                ea.email_id IN (SELECT id FROM emails em
                                                 WHERE em.gmail_message_id = s.payload->>'gmail_message_id'))
          THEN 'soft_recovered_invoice_no_attach'
        ELSE 'dead_letter'
      END AS verdict
      FROM stuck s
  ),
  recover_branch AS (
    UPDATE events e
       SET status       = 'processed',
           processed_at = NOW(),
           processing_started_at = NULL,
           processing_node_id    = NULL,
           error_message = CASE WHEN c.verdict LIKE 'soft%' THEN c.verdict ELSE error_message END
     FROM classified c
     WHERE e.id = c.id
       AND c.verdict <> 'dead_letter'
    RETURNING e.id, c.verdict
  ),
  recover_audit AS (
    INSERT INTO audit_log (pipeline, event_id, action, ai_parsed, result)
    SELECT 'master_router', rb.id, 'recovered_post_lease',
           jsonb_build_object('verdict', rb.verdict, 'fn', 'v3'),
           CASE WHEN rb.verdict LIKE 'soft%' THEN 'soft_success' ELSE 'success' END
      FROM recover_branch rb
    RETURNING 1
  ),
  dead_letter_branch AS (
    INSERT INTO dead_letter (event_id, pipeline, error_message, retry_count)
    SELECT c.id, 'stale_lease_recovery_v3',
           'v3 verdict=dead_letter on node ' || COALESCE(c.processing_node_id, '?'),
           c.retry_count
      FROM classified c
     WHERE c.verdict = 'dead_letter'
    ON CONFLICT (event_id) DO NOTHING
    RETURNING event_id
  ),
  -- V310 FIX: mark events failed for ALL dead_letter verdicts, not only the
  -- rows the insert above returned. dead_letter_branch is still materialised
  -- (so the INSERT executes), but the status transition keys off `classified`
  -- — an already-dead-lettered event now still leaves 'processing'.
  dead_letter_mark AS (
    UPDATE events e
       SET status = 'failed', processed_at = NOW(),
           processing_started_at = NULL, processing_node_id = NULL
      FROM classified c
     WHERE e.id = c.id
       AND c.verdict = 'dead_letter'
       AND e.status = 'processing'
    RETURNING e.id
  )
  SELECT
    (SELECT count(*) FROM recover_branch WHERE verdict NOT LIKE 'soft%'),
    (SELECT count(*) FROM recover_branch WHERE verdict     LIKE 'soft%'),
    (SELECT count(*) FROM dead_letter_mark)
  INTO v_recovered, v_soft, v_dead;

  RETURN QUERY SELECT v_recovered, v_soft, v_dead;
END;
$fn$;
