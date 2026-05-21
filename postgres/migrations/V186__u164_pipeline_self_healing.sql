-- =============================================================================
-- V186 — U164: pipeline self-healing
-- =============================================================================
-- recover_stale_leases_v2 dead-letters events after retry_count >= 3 if
-- downstream evidence is missing. But many "failures" are actually noOp-skip
-- or 0-rows-returned patterns where the downstream DID succeed (e.g. already
-- processed) — we just can't see evidence in the downstream table because
-- nothing changed.
--
-- v3 adds a "soft-recover" pass that completes events older than 30 min
-- regardless of retry count, provided the upstream payload looks like
-- something the downstream typically wouldn't have written even on success
-- (e.g. document.received for non-PDF MIME types, child.event.detected
-- with unknown classification).
--
-- Plus a pipeline_completion_lag_5m slug to surface drift before flood.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.recover_stale_leases_v3()
 RETURNS TABLE(recovered_count bigint, soft_recovered bigint, dead_lettered bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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

  -- Phase 2 (extended): retry-exhausted events
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
        -- Original downstream-present recovery (unchanged)
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

        -- NEW v3 soft-recovery: terminal-by-design cases
        -- Non-PDF document.received: Report Ingestion's skip branch handles it.
        WHEN s.event_type = 'document.received'
          AND (s.payload->>'mime_type') IS NOT NULL
          AND (s.payload->>'mime_type') <> 'application/pdf'
          THEN 'soft_recovered_nonpdf_doc'

        -- child.event.detected where Nanny couldn't classify a child:
        -- already handled inline by U151 T2 patch, but if it lingered, soft.
        WHEN s.event_type = 'child.event.detected'
          AND s.retry_count >= 3
          THEN 'soft_recovered_nanny'

        -- invoice.detected without an attachment (handled by U151 T1 inline,
        -- but soft-net any that slip through):
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
  dead_letter_mark AS (
    UPDATE events e
       SET status = 'failed', processed_at = NOW()
      FROM dead_letter_branch dlb
     WHERE e.id = dlb.event_id
    RETURNING e.id
  )
  SELECT
    (SELECT count(*) FROM recover_branch WHERE verdict NOT LIKE 'soft%'),
    (SELECT count(*) FROM recover_branch WHERE verdict     LIKE 'soft%'),
    (SELECT count(*) FROM dead_letter_branch)
  INTO v_recovered, v_soft, v_dead;

  RETURN QUERY SELECT v_recovered, v_soft, v_dead;
END;
$function$;

-- Slug to surface in-flight events stuck > 5 min per type
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'pipeline_completion_lag_5m',
  'Pipeline completion lag — events stuck > 5 min',
  'U164: surfaces drift before flood. Count of events still processing >5m per event_type.',
  E'SELECT event_type,
           count(*)::int AS stuck,
           MIN(processing_started_at) AS oldest_started,
           EXTRACT(EPOCH FROM (NOW() - MIN(processing_started_at)))::int AS oldest_age_sec,
           AVG(retry_count)::numeric(4,1) AS avg_retry
      FROM events
     WHERE status = ''processing''
       AND processing_started_at < NOW() - INTERVAL ''5 minutes''
     GROUP BY event_type
     ORDER BY 2 DESC',
  '{}', 'shared', true, NOW(), 'u164', 'u164'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

COMMIT;
