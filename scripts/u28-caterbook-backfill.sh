#!/bin/bash
# /home_ai/scripts/u28-caterbook-backfill.sh
#
# Backfill the Caterbook "Arrivals and Departures" emails in the info@
# inbox. Idempotent — ON CONFLICT DO NOTHING across all caterbook_* writes,
# so re-running is safe.
#
# Usage:
#   ./scripts/u28-caterbook-backfill.sh              # all matching emails
#   ./scripts/u28-caterbook-backfill.sh 10           # just the first 10 (oldest-first)
#
# Each ingest is ~1-2s. 141 emails ≈ 3-5 min.

set -euo pipefail
LIMIT=${1:-500}

# Search the inbox for every matching email, sort oldest-first.
echo "── discovering messages ──"
msgs=$(docker exec homeai-playwright python -c "
import urllib.request, json, urllib.parse
q = 'to:stay@malthousetintagel.com subject:\"The Olde Malthouse Inn: Arrivals and Departures\"'
url = 'http://google-fetch:8011/messages?account=info&max_results=500&q=' + urllib.parse.quote(q)
r = urllib.request.urlopen(url, timeout=60)
o = json.loads(r.read())
msgs = sorted((m for m in o['messages'] if 'internal_date' in m), key=lambda m: int(m['internal_date']))
print(len(msgs))
for m in msgs[:$LIMIT]:
    print(m['id'])
")
total=$(echo "$msgs" | head -1)
ids=$(echo "$msgs" | tail -n +2)
echo "── ingesting $(echo \"$ids\" | wc -l) of $total matching emails ──"

idx=0
fail=0
for mid in $ids; do
  idx=$((idx + 1))
  ts=$(date '+%H:%M:%S')
  result=$(docker exec homeai-playwright python -c "
import urllib.request, json, urllib.error
req = urllib.request.Request('http://localhost:8001/ingest/caterbook?account=info&message_id=$mid', method='POST')
try:
    r = urllib.request.urlopen(req, timeout=60)
    o = json.loads(r.read())
    print(f\"OK  report_date={o['report_date']}  obs={o['observations_inserted']}/{o['observations_inserted']+o['observations_skipped']}  arr={o['arrivals']} stay={o['stayovers']} dep={o['departures']}\")
except urllib.error.HTTPError as e:
    print(f\"HTTP{e.code} {e.read().decode()[:200]}\")
except Exception as e:
    print(f\"EXC {type(e).__name__}: {e}\")
" 2>&1) || result="EXC docker-exec-failed"
  if [[ "$result" == OK* ]]; then
    echo -e "$ts\t$idx/$total\t$mid\t$result"
  else
    fail=$((fail + 1))
    echo -e "$ts\t$idx/$total\t$mid\t$result"
  fi
done

echo
echo "── backfill done: $idx ingested, $fail failed ──"
exit $fail
