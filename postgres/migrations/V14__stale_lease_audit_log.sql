-- V14: have recover_stale_leases() write audit_log rows so we can see
--      when leases were recovered or dead-lettered, and from where.
--
-- Without this, the function is silent — Master Router calls it every 30s
-- and we have no record. After V13 it no longer floods dead_letter, so
-- we lost the only visibility we had into stale-lease activity.
--
-- Audit_log rows are only written when recovered_count > 0 OR
-- dead_lettered_count > 0 — quiet runs stay silent.

\set ON_ERROR_STOP on

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

  -- Telemetry: only emit audit_log when something actually happened.
  IF v_recovered > 0 OR v_dead_let > 0 THEN
    INSERT INTO audit_log (pipeline, action, pipeline_version, result,
                           ai_parsed)
    VALUES ('master_router',
            'stale_lease_recovery',
            '1.0',
            CASE WHEN v_dead_let > 0 THEN 'partial_failure' ELSE 'success' END,
            jsonb_build_object(
              'recovered_count',     v_recovered,
              'dead_lettered_count', v_dead_let,
              'lease_threshold_min', 10,
              'retry_limit',         3
            ));
  END IF;

  recovered_count     := v_recovered;
  dead_lettered_count := v_dead_let;
  RETURN NEXT;
END;
$fn$;

GRANT EXECUTE ON FUNCTION recover_stale_leases() TO homeai_pipeline;

SELECT 'recover_stale_leases() now writes audit_log on activity' AS check;
