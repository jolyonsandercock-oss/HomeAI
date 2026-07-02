#!/usr/bin/env bash
# u-deadletter-hygiene.sh — the grounded version of "Gap 3 / dead-letter reduction".
#
# Live reality (verified 2026-06-21): the dead_letter queue is NOT malformed-AI output.
# Of 57 unresolved, 55 were email.received events ALREADY status='processed' (phantom — the
# work succeeded, the flag never cleared); 2 were genuinely failed. So instead of an AI
# re-prompt agent (which would have nothing to retry), this does what reality needs:
#   1. PHANTOM-RESOLVE: dead_letter rows whose event is already 'processed' -> mark resolved.
#   2. BOUNDED RE-DRIVE: genuinely-failed recoverable events -> set 'pending' for master-router
#      to re-claim, once (retry_count<2), then leave for a human.
# Deterministic, idempotent, records an ops.pipeline_runs heartbeat. No LLM.
#
# (If malformed-AI dead-letters ever appear, add a re-prompt branch here — but per the live
#  data they don't, so it's intentionally not built. Verify before building.)
# Cron suggestion: 25 * * * *  (hourly).
set -uo pipefail
VT=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
PW=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=password secret/postgres 2>/dev/null)
psqlc(){ docker exec -i -e PGPASSWORD="$PW" homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 -tAq "$@"; }

read -r PHANTOM REDRIVEN REAPED <<<"$(psqlc <<'SQL' | tr '\n' ' '
SET app.current_entity='all'; SET app.current_realm='owner';
-- 1. phantom-resolve: underlying event already processed
WITH ph AS (
  UPDATE dead_letter d SET resolved=true, resolved_at=now(),
         resolution_notes='auto-hygiene: underlying event already processed'
  WHERE NOT d.resolved
    AND EXISTS (SELECT 1 FROM events e WHERE e.id=d.event_id AND e.status='processed')
  RETURNING 1)
SELECT count(*) FROM ph;
-- 2. bounded re-drive of genuinely-failed, recoverable events (once)
-- Uses the dedicated redrive_count (default 0): dead_letter.retry_count arrives
-- already =3 (inherited from the event's exhausted retries), so gating on it
-- made the re-drive a permanent no-op (0 re-driven ever, fixed 2026-07-02).
WITH rd AS (
  UPDATE events e SET status='pending', processing_started_at=NULL, processing_node_id=NULL, retry_count=0
  FROM dead_letter d
  WHERE d.event_id=e.id AND NOT d.resolved AND e.status='failed'
    AND COALESCE(d.redrive_count,0) < 1
    AND e.event_type NOT IN ('document.received')   -- known V250 quarantine; don't churn it
  RETURNING d.id),
bump AS (
  UPDATE dead_letter SET redrive_count=COALESCE(redrive_count,0)+1
  WHERE id IN (SELECT id FROM rd)
  RETURNING 1)
SELECT count(*) FROM bump;
-- 3. stuck-processing reaper: claims stranded by restarts go back to pending
WITH reaped AS (
  UPDATE events SET status='pending', processing_started_at=NULL, processing_node_id=NULL,
         retry_count=COALESCE(retry_count,0)+1
  WHERE status='processing' AND processing_started_at < now() - interval '1 hour'
    AND COALESCE(retry_count,0) < 3
  RETURNING 1)
SELECT count(*) FROM reaped;
-- 4. pipeline_runs retention (heartbeats are high-volume now)
DELETE FROM ops.pipeline_runs WHERE finished_at < now() - interval '30 days';
SQL
)"
echo "deadletter-hygiene: phantom-resolved=$PHANTOM re-driven=$REDRIVEN reaped=$REAPED"
echo "OPS_ROWS=$((PHANTOM + REDRIVEN + REAPED))"

# heartbeat
psqlc >/dev/null <<SQL
SET app.current_entity='all'; SET app.current_realm='owner';
INSERT INTO ops.pipeline_registry(name,kind,script_path,schedule_cron,target_rel,freshness_sql,freshness_sla_hours,notes)
VALUES('deadletter_hygiene','maintenance','scripts/u-deadletter-hygiene.sh','25 * * * *','dead_letter',
       'SELECT max(resolved_at) FROM dead_letter',6,'phantom-resolve + bounded re-drive')
ON CONFLICT(name) DO NOTHING;
SELECT ops.record_pipeline_run('deadletter_hygiene','ok',now(), ${PHANTOM:-0}+${REDRIVEN:-0}, 'phantom=${PHANTOM} redrive=${REDRIVEN}');
SQL
