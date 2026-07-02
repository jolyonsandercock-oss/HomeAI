#!/bin/bash
# /home_ai/scripts/u27-touchoffice-backfill.sh
#
# Backfill TouchOffice data across a date range. Each (date, site) is an
# independent /ingest/touchoffice call — failures on one day/site don't block
# the rest of the run. ON CONFLICT DO NOTHING in the INSERTs makes re-runs
# idempotent (already-loaded rows are silently skipped).
#
# Usage:
#   ./scripts/u27-touchoffice-backfill.sh START_DATE END_DATE [delay_seconds]
#
# Examples:
#   ./scripts/u27-touchoffice-backfill.sh 2026-04-11 2026-05-10              # last 30d
#   ./scripts/u27-touchoffice-backfill.sh 2023-05-11 2026-05-10 5            # 3 years, 5s gap
#
# Each day ~150s (both sites). 30d ≈ 75 min, 1100d ≈ 2 days. Output is a
# tab-separated log line per (date, site) so progress is easy to grep / tail.

set -euo pipefail
START=${1:?START_DATE (YYYY-MM-DD) required}
END=${2:?END_DATE (YYYY-MM-DD) required}
DELAY=${3:-3}

date -d "$START" '+%Y-%m-%d' >/dev/null 2>&1 || { echo "✗ bad START_DATE $START"; exit 1; }
date -d "$END"   '+%Y-%m-%d' >/dev/null 2>&1 || { echo "✗ bad END_DATE $END";   exit 1; }

cur=$(date -d "$START" '+%Y-%m-%d')
stop=$(date -d "$END + 1 day" '+%Y-%m-%d')
total_days=$(( ($(date -d "$END" '+%s') - $(date -d "$START" '+%s')) / 86400 + 1 ))
echo "── backfill $START → $END ($total_days days, ${DELAY}s gap between days) ──"

day_idx=0
while [[ "$cur" != "$stop" ]]; do
  day_idx=$((day_idx + 1))
  for site in malthouse sandwich; do
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    resp=$(docker exec homeai-playwright python -c "
import urllib.request, json, urllib.error, sys
u = 'http://localhost:8001/ingest/touchoffice?site=$site&date=$cur'
req = urllib.request.Request(u, method='POST')
try:
    r = urllib.request.urlopen(req, timeout=600)
    o = json.loads(r.read())
    ws = o.get('widgets', {})
    parts = []
    for w in ('fixed_totals','department_sales','plu_sales'):
        s = ws.get(w, {})
        if s.get('success'): parts.append(f'{w}={s.get(\"inserted\",0)}/{s.get(\"scraped\",0)}')
        else: parts.append(f'{w}=FAIL')
    print(f'OK  {o.get(\"scrape_runtime_ms\",0)}ms  ' + '  '.join(parts))
except urllib.error.HTTPError as e:
    print(f'HTTP{e.code} {e.read().decode()[:200]}')
except Exception as e:
    print(f'EXC {type(e).__name__}: {e}')
" 2>&1) || resp="EXC docker-exec-failed"
    echo -e "$ts\tday=$day_idx/$total_days\t$cur\t$site\t$resp"
  done
  sleep "$DELAY"
  cur=$(date -d "$cur + 1 day" '+%Y-%m-%d')
done

echo "── backfill complete ──"
