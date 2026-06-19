#!/usr/bin/env bash
# u-pipeline-freshness-watchdog.sh — Phase 0.3 of the Option B consolidation.
# Runs ops.check_freshness() over the pipeline registry; raises a mart.exceptions
# row for each STALE/NO_DATA pipeline (upsert-guarded so it never spams — one open
# row per pipeline) and auto-resolves pipelines that have recovered. This is the
# safety net cron lacked: silent pipeline failures now alert.
set -uo pipefail
LOGDIR=/home_ai/logs; mkdir -p "$LOGDIR"; LOG="$LOGDIR/pipeline-freshness-watchdog.log"
VT=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
PG_PW=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=password secret/postgres 2>/dev/null)
{
echo "=== $(date -Is) pipeline freshness watchdog ==="
docker exec -i -e PGPASSWORD="$PG_PW" homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 <<'SQL'
CREATE TEMP TABLE _fresh AS SELECT * FROM ops.check_freshness();
-- raise for newly-stale (one open exception per pipeline)
INSERT INTO mart.exceptions (severity, kind, source, transaction_date, summary, detail, status, realm)
SELECT CASE WHEN f.status='NO_DATA' THEN 'high' ELSE 'medium' END, 'pipeline_stale', f.name, current_date,
       'Pipeline '||f.name||' '||f.status||' (age '||COALESCE(f.age_hours::text,'?')||'h vs SLA '||f.sla_hours||'h)',
       jsonb_build_object('age_hours',f.age_hours,'sla_hours',f.sla_hours,'newest',f.newest),
       'open','work'
FROM _fresh f
WHERE f.status<>'ok'
  AND NOT EXISTS (SELECT 1 FROM mart.exceptions e WHERE e.kind='pipeline_stale' AND e.source=f.name AND e.status='open');
-- auto-resolve recovered pipelines
UPDATE mart.exceptions e SET status='resolved'
WHERE e.kind='pipeline_stale' AND e.status='open'
  AND NOT EXISTS (SELECT 1 FROM _fresh f WHERE f.name=e.source AND f.status<>'ok');
SELECT name, status, age_hours, sla_hours FROM _fresh WHERE status<>'ok' ORDER BY status, name;
SQL
echo "=== $(date -Is) done (rc=$?) ==="
} >> "$LOG" 2>&1
