#!/bin/bash
# /home_ai/scripts/u27-touchoffice-daily.sh
#
# Daily TouchOffice scrape + ingest for both sites. Runs each site as a
# separate call so a failure on one doesn't block the other. Date defaults
# to yesterday; override with the first positional arg (ISO YYYY-MM-DD).
#
# Per-widget failures inside each site call are isolated by the /ingest
# endpoint's independent try/except — they show up as success=false rows
# in touchoffice_scrapes without blocking the other widgets.
#
# Run via cron, n8n Schedule Trigger, or by hand for backfill:
#   ./scripts/u27-touchoffice-daily.sh                # yesterday
#   ./scripts/u27-touchoffice-daily.sh 2026-05-10     # specific date

set -uo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YEL='\033[0;33m'; NC='\033[0m'

DATE=${1:-$(date -d 'yesterday' '+%Y-%m-%d')}
SITES=(malthouse sandwich)
ENDPOINT_HOST=homeai-playwright
ENDPOINT_PORT=8001

if ! docker ps --filter "name=$ENDPOINT_HOST" --filter status=running --format '{{.Names}}' | grep -q "$ENDPOINT_HOST"; then
  echo -e "${RED}✗${NC} $ENDPOINT_HOST is not running"; exit 1
fi

overall_rc=0
# U207 — retry up to 3 times with 30s backoff on transient (DNS / 5xx) failures.
# 2026-05-20 cron hit net::ERR_NAME_NOT_RESOLVED for touchoffice.net once and
# silently lost the day; this loop catches that class of transient.
MAX_ATTEMPTS=3
for site in "${SITES[@]}"; do
  echo -e "${YEL}→${NC} $site / $DATE"
  url="http://localhost:${ENDPOINT_PORT}/ingest/touchoffice?site=${site}&date=${DATE}"
  attempt=0
  while :; do
    attempt=$((attempt+1))
    resp=$(docker exec "$ENDPOINT_HOST" python -c "
import urllib.request, json, urllib.error, sys
req = urllib.request.Request('$url', method='POST')
try:
    r = urllib.request.urlopen(req, timeout=300)
    print(r.read().decode())
except urllib.error.HTTPError as e:
    print(json.dumps({'_http': e.code, '_error': e.read().decode()[:600]}))
    sys.exit(2)
")
    rc=$?
    # Retry on rc != 0 (HTTP error) OR success but body contains 'scrape failed'
    if [[ $rc -ne 0 ]] || echo "$resp" | grep -q 'scrape failed\|ERR_NAME_NOT_RESOLVED'; then
      if [[ $attempt -lt $MAX_ATTEMPTS ]]; then
        echo -e "  ${YEL}↺${NC} attempt $attempt failed, retrying in 30s…"
        sleep 30
        continue
      fi
    fi
    break
  done
  if [[ $rc -eq 0 ]] && ! echo "$resp" | grep -q 'scrape failed\|ERR_NAME_NOT_RESOLVED'; then
    summary=$(echo "$resp" | python3 -c "
import json,sys
o=json.load(sys.stdin)
ws=o.get('widgets',{})
parts=[]
for w in ('fixed_totals','department_sales','plu_sales'):
    s=ws.get(w,{})
    if s.get('success'): parts.append(f'{w}={s.get(\"inserted\",0)}/{s.get(\"scraped\",0)}')
    else: parts.append(f'{w}=FAIL({s.get(\"error\",\"?\")[:50]})')
print('  '.join(parts) + f'  runtime={o.get(\"scrape_runtime_ms\",0)}ms')")
    echo -e "  ${GREEN}✓${NC} $summary"
  else
    echo -e "  ${RED}✗${NC} ingest failed: $resp"
    overall_rc=1
  fi
done

exit $overall_rc
