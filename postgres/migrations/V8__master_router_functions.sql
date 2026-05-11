-- V8__master_router_functions.sql
-- Two SECURITY DEFINER functions for Master Router. Owned by postgres
-- (superuser), so they bypass RLS without needing SET LOCAL — which n8n's
-- Postgres v2.5 executeQuery silently strips the RETURNING rows from when
-- combined with the UPDATE.
--
-- Discovered: 2026-05-08 sprint Item 1 blocker. Direct UPDATE...RETURNING
-- queries via n8n returned {"success": true} instead of the row data.
-- Wrapping logic in a SQL function called as `SELECT * FROM fn();` makes
-- n8n see a single SELECT statement and capture rows correctly.
--
-- Idempotent: CREATE OR REPLACE FUNCTION + idempotent GRANTS.

\set ON_ERROR_STOP on

-- ─────────────────────────────────────────────────────────────────
-- claim_event_batch()
-- Claims up to 10 pending events older than 7 days, marks them as
-- processing, returns the claimed rows for routing.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION claim_event_batch()
RETURNS TABLE(
  id BIGINT,
  event_type TEXT,
  source TEXT,
  entity_id INT,
  payload JSONB,
  trace_id UUID,
  parent_event_id BIGINT,
  idempotency_key TEXT,
  pipeline_version TEXT,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN QUERY
  UPDATE events e
     SET status = 'processing',
         processing_started_at = NOW(),
         processing_node_id = 'master-router'
   WHERE e.id IN (
     SELECT inner_e.id FROM events inner_e
      WHERE inner_e.status = 'pending'
        AND inner_e.created_at > NOW() - INTERVAL '7 days'
      ORDER BY inner_e.created_at ASC
      LIMIT 10
      FOR UPDATE SKIP LOCKED
   )
  RETURNING e.id, e.event_type, e.source, e.entity_id,
            e.payload, e.trace_id, e.parent_event_id,
            e.idempotency_key, e.pipeline_version, e.created_at;
END;
$$;

GRANT EXECUTE ON FUNCTION claim_event_batch() TO homeai_pipeline;

-- ─────────────────────────────────────────────────────────────────
-- recover_stale_leases()
-- Returns events that have been processing >10 min back to pending
-- (incrementing retry_count), and dead-letters those that have hit
-- the retry limit.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION recover_stale_leases()
RETURNS TABLE(recovered_count BIGINT, dead_lettered_count BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_recovered  BIGINT;
  v_dead_let   BIGINT;
BEGIN
  WITH recovered AS (
    UPDATE events
       SET status = 'pending',
           processing_started_at = NULL,
           processing_node_id = NULL,
           retry_count = retry_count + 1
     WHERE status = 'processing'
       AND processing_started_at < NOW() - INTERVAL '10 minutes'
       AND retry_count < 3
    RETURNING id
  )
  SELECT count(*) INTO v_recovered FROM recovered;

  WITH deadlettered AS (
    INSERT INTO dead_letter (event_id, pipeline, error_message, retry_count)
    SELECT e.id,
           'stale_lease_recovery',
           'Max retries exceeded — stale on node ' || COALESCE(e.processing_node_id, 'unknown'),
           e.retry_count
      FROM events e
     WHERE e.status = 'processing'
       AND e.processing_started_at < NOW() - INTERVAL '10 minutes'
       AND e.retry_count >= 3
    ON CONFLICT DO NOTHING
    RETURNING event_id
  )
  SELECT count(*) INTO v_dead_let FROM deadlettered;

  recovered_count := v_recovered;
  dead_lettered_count := v_dead_let;
  RETURN NEXT;
END;
$$;

GRANT EXECUTE ON FUNCTION recover_stale_leases() TO homeai_pipeline;

-- Verification
SELECT 'claim_event_batch grants: ' ||
       string_agg(grantee, ',') AS check
  FROM information_schema.role_routine_grants
 WHERE routine_name = 'claim_event_batch'
   AND grantee != 'postgres';

SELECT 'recover_stale_leases grants: ' ||
       string_agg(grantee, ',') AS check
  FROM information_schema.role_routine_grants
 WHERE routine_name = 'recover_stale_leases'
   AND grantee != 'postgres';
