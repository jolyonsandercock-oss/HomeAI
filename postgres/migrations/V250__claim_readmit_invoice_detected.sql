-- V250 — re-admit invoice.detected to claim_event_batch (P2 reactivated 2026-06-08).
--
-- The V224 stopgap excluded document.received / invoice.detected /
-- child.event.detected from claiming so their events wouldn't be routed to
-- dead/broken pipelines (they accumulated as pending). Invoice Pipeline (P2) is
-- now active and proven (06-06 + 06-08 drains, 0 flood), so invoice.detected is
-- re-admitted here. document.received (Report Ingestion) and child.event.detected
-- (Nanny) remain excluded until those backlogs are deliberately drained.
--
-- Reverse: re-add 'invoice.detected' to the NOT IN list.
CREATE OR REPLACE FUNCTION public.claim_event_batch()
 RETURNS TABLE(id bigint, event_type text, source text, entity_id integer, payload jsonb, trace_id uuid, parent_event_id bigint, idempotency_key text, pipeline_version text, created_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE claimed_ids BIGINT[];
BEGIN
  WITH to_claim AS (
    SELECT inner_e.id FROM events inner_e
     WHERE inner_e.status='pending' AND inner_e.created_at > NOW()-INTERVAL '7 days'
       AND inner_e.event_type NOT IN ('document.received','child.event.detected')
     ORDER BY inner_e.created_at ASC LIMIT 10 FOR UPDATE SKIP LOCKED),
  updated AS (
    UPDATE events SET status='processing', processing_started_at=NOW(), processing_node_id='master-router'
     WHERE events.id IN (SELECT to_claim.id FROM to_claim) RETURNING events.id)
  SELECT array_agg(updated.id) INTO claimed_ids FROM updated;
  RETURN QUERY SELECT e.id,e.event_type,e.source,e.entity_id,e.payload,e.trace_id,e.parent_event_id,e.idempotency_key,e.pipeline_version,e.created_at FROM events e WHERE e.id=ANY(claimed_ids);
END $function$;
