#!/bin/bash
# /home_ai/scripts/u28-caterbook-daily.sh
#
# Daily 07:00 Caterbook "Arrivals and Departures" ingest. Pulls every
# matching email received in the last 2 days (covers yesterday and today,
# tolerates a missed run). Idempotent — ON CONFLICT DO NOTHING.
#
# Hardening (2026-05-18):
#   - Retry-wrap the initial Gmail query (3 attempts, 10s backoff) so a
#     transient 5xx from google-fetch no longer silently loses a day.
#   - Exit non-zero on empty msgs (caterbook always emails daily, so empty
#     after retries means upstream is broken — heartbeat picks this up).
#   - Post-run sanity check: confirm yesterday's snapshot landed in DB.

set -uo pipefail

GMAIL_QUERY='newer_than:2d to:stay@malthousetintagel.com subject:"The Olde Malthouse Inn: Arrivals and Departures"'

echo "── caterbook daily $(date +%F\ %H:%M) ──"

# Fetch message IDs from google-fetch, retry on transient errors.
fetch_msgs() {
  local attempt
  for attempt in 1 2 3; do
    out=$(docker exec homeai-playwright python -c "
import urllib.request, json, urllib.parse, sys
q = '$GMAIL_QUERY'
url = 'http://google-fetch:8011/messages?account=info&max_results=50&q=' + urllib.parse.quote(q)
try:
    r = urllib.request.urlopen(url, timeout=30)
    o = json.loads(r.read())
    msgs = sorted((m for m in o['messages'] if 'internal_date' in m), key=lambda m: int(m['internal_date']))
    for m in msgs:
        print(m['id'])
    sys.exit(0)
except Exception as e:
    sys.stderr.write(f'FETCH_ERR: {type(e).__name__}: {e}\n')
    sys.exit(1)
" 2>&1)
    if [ $? -eq 0 ]; then
      printf '%s\n' "$out"
      return 0
    fi
    echo "── attempt $attempt failed: ${out:0:200}" >&2
    sleep 10
  done
  return 1
}

if ! msgs=$(fetch_msgs); then
  echo "✗ Gmail query failed after 3 retries — aborting" >&2
  exit 1
fi

if [ -z "$msgs" ]; then
  echo "✗ No matching emails in newer_than:2d window — caterbook may have stopped sending. Investigate." >&2
  exit 1
fi

idx=0; fail=0
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

echo "── ingest done: $idx emails, $fail failures ──"

# Sanity: yesterday's snapshot must exist in DB. If not, alarm.
y=$(date -d 'yesterday' +%F)
snap_count=$(docker exec homeai-postgres psql -U postgres -d homeai -tAc \
  "SELECT count(*) FROM caterbook_daily_snapshots WHERE report_date = '$y'" 2>/dev/null || echo 0)
if [ "${snap_count:-0}" -lt 1 ]; then
  echo "✗ SANITY: no caterbook snapshot for $y — heartbeat will flag this" >&2
  exit 2
fi
echo "✓ sanity: snapshot for $y present"
exit $fail
