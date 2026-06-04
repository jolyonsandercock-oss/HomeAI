-- V224 — master-router resilience stopgap: claim_event_batch() skips event
-- types whose downstream pipeline is currently broken, so one bad pipeline
-- can't poison the shared mixed batch and wedge the whole queue.
--
-- 2026-06-04: document.received → Report Ingestion P9 (HTTP 500),
-- invoice.detected → Invoice Pipeline P2 (404, deactivated/superseded by the
-- u35 shell chain), child.event.detected → Nanny P8 (500). All three were
-- re-poisoning the batch and stalling email.received catch-up after the
-- DeadLetterFlood pause. Excluding them lets email flow; they accumulate as
-- harmless 'pending' until their pipelines are fixed.
--
-- REMOVE the exclusion (or trim it) as each pipeline is fixed, then the parked
-- events drain. Proper long-term fix = per-event error isolation in the
-- master-router route nodes (continueOnError) so no single type can poison.

CREATE OR REPLACE FUNCTION public.claim_event_batch()
RETURNS TABLE(id bigint, event_type text, source text, entity_id integer, payload jsonb, trace_id uuid, parent_event_id bigint, idempotency_key text, pipeline_version text, created_at timestamp with time zone)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  claimed_ids BIGINT[];
BEGIN
  WITH to_claim AS (
    SELECT inner_e.id FROM events inner_e
     WHERE inner_e.status = 'pending'
       AND inner_e.created_at > NOW() - INTERVAL '7 days'
       AND inner_e.event_type NOT IN ('document.received','invoice.detected','child.event.detected')
     ORDER BY inner_e.created_at ASC
     LIMIT 10
     FOR UPDATE SKIP LOCKED
  ),
  updated AS (
    UPDATE events SET status='processing',
                      processing_started_at = NOW(),
                      processing_node_id = 'master-router'
     WHERE events.id IN (SELECT to_claim.id FROM to_claim)
    RETURNING events.id
  )
  SELECT array_agg(updated.id) INTO claimed_ids FROM updated;

  RETURN QUERY
  SELECT e.id, e.event_type, e.source, e.entity_id, e.payload, e.trace_id,
         e.parent_event_id, e.idempotency_key, e.pipeline_version, e.created_at
    FROM events e WHERE e.id = ANY(claimed_ids);
END;
$function$;
