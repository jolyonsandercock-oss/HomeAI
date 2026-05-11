#!/bin/bash
# /home_ai/scripts/u28-caterbook-daily.sh
#
# Daily 07:00 Caterbook "Arrivals and Departures" ingest. Pulls every
# matching email received in the last 2 days (covers yesterday and today,
# tolerates a missed run). Idempotent — ON CONFLICT DO NOTHING.

set -uo pipefail

msgs=$(docker exec homeai-playwright python -c "
import urllib.request, json, urllib.parse
q = 'newer_than:2d to:stay@malthousetintagel.com subject:\"The Olde Malthouse Inn: Arrivals and Departures\"'
url = 'http://google-fetch:8011/messages?account=info&max_results=50&q=' + urllib.parse.quote(q)
r = urllib.request.urlopen(url, timeout=30)
o = json.loads(r.read())
msgs = sorted((m for m in o['messages'] if 'internal_date' in m), key=lambda m: int(m['internal_date']))
for m in msgs:
    print(m['id'])
")

idx=0; fail=0
echo "── caterbook daily $(date +%F\ %H:%M) ──"
for mid in $msgs; do
  idx=$((idx + 1))
  res=$(docker exec homeai-playwright python -c "
import urllib.request, json, urllib.error
req = urllib.request.Request('http://localhost:8001/ingest/caterbook?account=info&message_id=$mid', method='POST')
try:
    r = urllib.request.urlopen(req, timeout=60)
    o = json.loads(r.read())
    print(f\"OK  date={o['report_date']}  obs={o['observations_inserted']}/{o['observations_inserted']+o['observations_skipped']}  a/s/d={o['arrivals']}/{o['stayovers']}/{o['departures']}\")
except urllib.error.HTTPError as e:
    print(f\"HTTP{e.code} {e.read().decode()[:200]}\")
" 2>&1)
  [[ "$res" == OK* ]] || fail=$((fail + 1))
  echo -e "$(date +%H:%M:%S)\t$idx\t$mid\t$res"
done

echo "── done: $idx emails, $fail failures ──"
exit $fail
