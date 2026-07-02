#!/bin/bash
# /home_ai/scripts/u203-perf-audit.sh
# U203 — weekly perf audit. Captures p50/p95 response time per slug + key
# endpoint via curl timing. Stores in perf_audit table.
# Cron: 0 5 * * 0 (Sun 05:00 after weekly backup)

set -euo pipefail
LOG=/home_ai/logs/u203-perf.log
TS=$(date -Iseconds)

# Ensure table exists
docker exec homeai-postgres psql -U postgres -d homeai -c "
CREATE TABLE IF NOT EXISTS perf_audit (
  id BIGSERIAL PRIMARY KEY,
  audit_ts TIMESTAMPTZ NOT NULL DEFAULT now(),
  endpoint TEXT NOT NULL,
  p50_ms NUMERIC(8,2),
  p95_ms NUMERIC(8,2),
  max_ms NUMERIC(8,2),
  runs INT NOT NULL,
  realm TEXT NOT NULL DEFAULT 'work'
);
CREATE INDEX IF NOT EXISTS idx_perf_audit_endpoint_ts ON perf_audit (endpoint, audit_ts DESC);" >/dev/null 2>&1

ENDPOINTS=(
  /api/healthz
  /api/snapshot
  /api/recent
  /api/agents
  /api/finance/slug/today_kpis_work
  /api/finance/slug/frontend_today_gross
  /api/finance/slug/frontend_action_queue
  /api/finance/slug/staff_on_rota_today
  /api/finance/slug/dashboard_week_strip
  /api/finance/slug/menu_performance_today
  /api/finance/slug/revenue_today_vs_typical
  /api/finance/slug/data_source_freshness
)

for ep in "${ENDPOINTS[@]}"; do
  TIMES=()
  for i in 1 2 3 4 5; do
    t=$(curl -s -m 30 -H "X-Realm: owner" -w "%{time_total}\n" -o /dev/null "http://100.104.82.53:8090$ep" 2>/dev/null || echo "30.0")
    TIMES+=("$t")
  done
  STATS=$(python3 -c "
ts = [float(x) * 1000 for x in '${TIMES[*]}'.split()]
ts.sort()
n = len(ts)
p50 = ts[n//2]
p95 = ts[int(n*0.95)]
print(f'{p50:.2f} {p95:.2f} {max(ts):.2f} {n}')
")
  P50=$(echo "$STATS" | awk '{print $1}')
  P95=$(echo "$STATS" | awk '{print $2}')
  MAX=$(echo "$STATS" | awk '{print $3}')
  RUNS=$(echo "$STATS" | awk '{print $4}')
  docker exec homeai-postgres psql -U postgres -d homeai -c "
INSERT INTO perf_audit (endpoint, p50_ms, p95_ms, max_ms, runs)
VALUES ('$ep', $P50, $P95, $MAX, $RUNS);" >/dev/null 2>&1 \
    || echo "  WARN: perf_audit insert failed for $ep" >> "$LOG"
  printf '  %-50s p50=%6.0fms p95=%6.0fms max=%6.0fms\n' "$ep" "$P50" "$P95" "$MAX" >> "$LOG"
done

echo "$TS  perf audit complete" >> "$LOG"

# Slug for surfacing trend
docker exec homeai-postgres psql -U postgres -d homeai -c "
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'perf_audit_latest',
  'Performance audit — latest snapshot',
  'U203: p50/p95/max ms per endpoint, latest audit run.',
  E'SELECT endpoint, p50_ms, p95_ms, max_ms, audit_ts
    FROM perf_audit pa
    WHERE pa.audit_ts = (SELECT max(audit_ts) FROM perf_audit)
    ORDER BY p95_ms DESC',
  '{}', 'shared', true, NOW(), 'u203', 'u203'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();" >/dev/null 2>&1 \
  || echo "$TS  WARN: query_whitelist slug registration failed" >> "$LOG"
