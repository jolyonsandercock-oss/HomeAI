-- V234 — re-admit invoice.detected to the Master Router's claim batch.
--
-- Context: the V224 stopgap excluded invoice.detected (and document.received,
-- child.event.detected) from claim_event_batch while Invoice Pipeline (P2) was
-- broken. P2 is now fixed end-to-end (DWD attachment fetch via google-fetch +
-- four Write/Outcome bugs: audit-CTE id->audit_id, Haiku ```json fence strip,
-- trigger-event completion, and parameterized Write node), proven on a clean
-- canary across both auth modes. The Master Router's 'Trigger Invoice Pipeline'
-- node was also re-enabled (it had been disabled in the same stopgap; that change
-- lives in n8n's workflow store, applied via scripts/enable-router-invoice-trigger.py).
--
-- This migration makes the re-admit reproducible: only document.received and
-- child.event.detected remain excluded (both are handled outside the generic
-- claim path). Body is otherwise identical to the prior definition.
BEGIN;

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

COMMIT;
