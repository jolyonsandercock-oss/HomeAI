-- =============================================================================
-- V261 — U250 P2: event backlog drain + claim re-admission
-- =============================================================================
-- Findings (2026-06-10 diagnosis):
--   1. 4,400+ events were handled but never stamped processed_at:
--      - email.classified / invoice.unmatched / bank.imported /
--        partition.ensured are inserted BORN-terminal ('processed'/'done')
--        without processed_at (emitters fixed 2026-06-10 via
--        scripts/u250-fix-event-stamping.py — 4 workflow patches);
--      - email.received is closed by the u239 stopgap sweep, which set
--        status='processed' without processed_at (sweep fixed same day).
--      Backfill below stamps them; proof of consumption per type:
--        email.received → its email row exists (verified: 0 rows lack one);
--        email.classified → born processed at INSERT (stamp = created_at);
--        done-status types → terminal-by-design record events.
--   2. document.received + child.event.detected were excluded from
--      claim_event_batch by V224 (2026-06-04) because P9/Nanny then 500'd.
--      Both pipelines were patched 2026-05-21 and verified healthy today by
--      manually firing real pending events (P9 → skipped_already_processed,
--      Nanny → nanny_haiku_parse_fail graceful-terminal). V250 re-admitted
--      only invoice.detected; this completes the V224 cleanup — no
--      exclusions remain. All pending rows of both types are < 7 days old,
--      so the router drains them on its own.
--   3. 233 failed document.received (DL-flood era, ≤2026-06-04) stamped as
--      terminally failed; status left 'failed' for the record.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', true);

-- ── preconditions ────────────────────────────────────────────────────────────
DO $$
DECLARE n int;
BEGIN
    -- every processed-status email.received must have its email row (proof)
    SELECT count(*) INTO n FROM events e
     WHERE e.event_type='email.received' AND e.status='processed'
       AND e.processed_at IS NULL
       AND NOT EXISTS (SELECT 1 FROM emails em
                        WHERE em.gmail_message_id = e.payload->>'gmail_message_id');
    IF n <> 0 THEN
        RAISE EXCEPTION 'V261 precondition: % processed email.received rows lack an email row', n;
    END IF;
END $$;

-- ── 1. stamp handled-but-unstamped events ────────────────────────────────────
DO $$
DECLARE r int; total int := 0;
BEGIN
    UPDATE events SET processed_at = created_at
     WHERE event_type='email.classified' AND status='processed' AND processed_at IS NULL;
    GET DIAGNOSTICS r = ROW_COUNT; total := total + r;
    RAISE NOTICE 'V261: email.classified stamped %', r;

    UPDATE events SET processed_at = COALESCE(processing_started_at, created_at)
     WHERE event_type='email.received' AND status='processed' AND processed_at IS NULL;
    GET DIAGNOSTICS r = ROW_COUNT; total := total + r;
    RAISE NOTICE 'V261: email.received stamped %', r;

    UPDATE events SET processed_at = created_at
     WHERE status='done' AND processed_at IS NULL;
    GET DIAGNOSTICS r = ROW_COUNT; total := total + r;
    RAISE NOTICE 'V261: done-status (invoice.unmatched/bank.imported/partition.ensured) stamped %', r;

    UPDATE events SET processed_at = COALESCE(processing_started_at, created_at)
     WHERE status='failed' AND processed_at IS NULL;
    GET DIAGNOSTICS r = ROW_COUNT; total := total + r;
    RAISE NOTICE 'V261: failed-status (DL-flood era document.received) stamped %', r;

    UPDATE events SET status='processed', processed_at=NOW(),
                      error_message='u250_closed_stale_test_event'
     WHERE event_type='system.test' AND status='pending' AND processed_at IS NULL;
    GET DIAGNOSTICS r = ROW_COUNT; total := total + r;
    RAISE NOTICE 'V261: system.test closed %', r;

    INSERT INTO audit_log (pipeline, action, record_type, ai_parsed, result, realm)
    VALUES ('U250', 'event_backlog_stamp_backfill', 'events',
            jsonb_build_object('rows_stamped', total,
                               'reason', 'born-terminal inserts + u239 sweep never set processed_at; emitters fixed 2026-06-10'),
            'success', 'owner');
END $$;

-- ── postcondition: nothing terminal is unstamped ─────────────────────────────
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM events
     WHERE processed_at IS NULL AND status NOT IN ('pending','processing');
    IF n <> 0 THEN
        RAISE EXCEPTION 'V261 postcondition: % terminal-status events still unstamped', n;
    END IF;
END $$;

-- ── 2. claim_event_batch: remove the V224 exclusions (V224 cleanup complete) ──
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
     ORDER BY inner_e.created_at ASC
     LIMIT 10
     FOR UPDATE SKIP LOCKED),
  updated AS (
    UPDATE events SET status='processing', processing_started_at=NOW(), processing_node_id='master-router'
     WHERE events.id IN (SELECT to_claim.id FROM to_claim) RETURNING events.id)
  SELECT array_agg(updated.id) INTO claimed_ids FROM updated;
  RETURN QUERY SELECT e.id,e.event_type,e.source,e.entity_id,e.payload,e.trace_id,e.parent_event_id,e.idempotency_key,e.pipeline_version,e.created_at FROM events e WHERE e.id=ANY(claimed_ids);
END
$function$;

-- ── 3. resolve the 47 stale_lease_recovery_v3 dead letters ───────────────────
DO $$
DECLARE r int;
BEGIN
    UPDATE dead_letter dl
       SET resolved = true, resolved_at = NOW(),
           resolution_notes =
             'U250: underlying email.received event was reprocessed successfully '
             || '(status=processed, processed_at set). Root cause: n8n restart '
             || '2026-06-08T05:23Z left claims stale mid-flight; '
             || 'recover_stale_leases_v3 dead-lettered the retry-exhausted ones, '
             || 'then they reprocessed after the restart. No data loss.'
      FROM events e
     WHERE dl.event_id = e.id
       AND NOT dl.resolved
       AND dl.pipeline = 'stale_lease_recovery_v3'
       AND e.status = 'processed' AND e.processed_at IS NOT NULL;
    GET DIAGNOSTICS r = ROW_COUNT;
    IF r <> 47 THEN
        RAISE EXCEPTION 'V261: expected to resolve 47 dead letters, resolved %', r;
    END IF;
    RAISE NOTICE 'V261: resolved % dead letters', r;
END $$;

-- ── postcondition: no unresolved dead letters ────────────────────────────────
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM dead_letter WHERE NOT resolved;
    IF n <> 0 THEN
        RAISE EXCEPTION 'V261 postcondition: % dead letters still unresolved', n;
    END IF;
END $$;

COMMIT;
