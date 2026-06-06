-- V235 — re-exclude invoice.detected from the Master Router claim (reverts V234).
--
-- U244 reconciliation: Invoice Pipeline P2 was deliberately deactivated +
-- superseded on 2026-05-30 (MASTER §3) by the u95→u35→u36 harvester chain writing
-- vendor_invoice_inbox. On 2026-06-06 P2 was temporarily revived/drained, which
-- re-admitted invoice.detected (V234) and left P2 writing the legacy `invoices`
-- table in parallel with the canonical harvester. This restores the documented
-- state: invoice.detected is NOT claimed; the harvester is the single invoice path.
-- (P2 itself is set active=false separately.)
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
       AND inner_e.event_type NOT IN ('document.received','invoice.detected','child.event.detected')
     ORDER BY inner_e.created_at ASC LIMIT 10 FOR UPDATE SKIP LOCKED),
  updated AS (
    UPDATE events SET status='processing', processing_started_at=NOW(), processing_node_id='master-router'
     WHERE events.id IN (SELECT to_claim.id FROM to_claim) RETURNING events.id)
  SELECT array_agg(updated.id) INTO claimed_ids FROM updated;
  RETURN QUERY SELECT e.id,e.event_type,e.source,e.entity_id,e.payload,e.trace_id,e.parent_event_id,e.idempotency_key,e.pipeline_version,e.created_at FROM events e WHERE e.id=ANY(claimed_ids);
END $function$;

COMMIT;
