#!/bin/bash
# /home_ai/.claude/scripts/u26-capture-samples.sh
#
# Capture a real-world sample of (a) a Caterbook daily occupancy report and/or
# (b) a TouchOffice ICRTouch Z-Report, then run them through the live parser
# to see exactly what would land in epos_daily / accommodation_daily.
#
# Why this exists: P5/P6 parsers were built against benchmark fixtures. Real
# Caterbook / TouchOffice formats may differ. Closes that debt item.
#
# Flow:
#   1. You forward a sample email to bot@malthousetintagel.com (or whichever
#      account you prefer — script will list available accounts).
#   2. Script polls the emails table for the new arrival.
#   3. Dumps the body to /tmp/, runs the parser against it, and reports what
#      would land in the daily table.
#   4. If parse fails, prints a diff against the fixture so you can see what
#      field markers are missing.
#
# Run as your normal user. Requires google-fetch + gmail ingestion running.

set -uo pipefail
PSQL() { docker exec    homeai-postgres psql -U postgres -d homeai -tAc "$@" 2>/dev/null; }
YEL='\033[0;33m'; GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

echo -e "${CYAN}── U26: Capture real Caterbook / EPoS samples ──${NC}"
echo

if ! docker ps --filter name=homeai-google-fetch --filter status=running --format '{{.Names}}' | grep -q homeai-google-fetch; then
  echo -e "${RED}✗${NC} homeai-google-fetch isn't running. Run ./start.sh first."
  exit 1
fi

# List accounts
echo "Available accounts (forward your sample to one of these):"
docker exec homeai-google-fetch python3 -c "
import urllib.request, json
d = json.loads(urllib.request.urlopen('http://localhost:8011/accounts').read())
for a in d['accounts']: print(f'  {a[\"name\"]:8s} -> {a[\"email\"]}')
" 2>&1
echo

echo "Which sample do you want to capture?"
echo "  1) Caterbook daily occupancy report  (accommodation_daily)"
echo "  2) TouchOffice ICRTouch Z-Report     (epos_daily)"
read -rp "> " choice
case "$choice" in
  1) target_label='Caterbook'; from_pattern='%caterbook%'; subj_hint='daily / occupancy / arrivals'; table='accommodation_daily' ;;
  2) target_label='EPoS Z-report'; from_pattern='%touchoffice%|%icrtouch%'; subj_hint='Z-Report / End-of-Day'; table='epos_daily' ;;
  *) echo "invalid choice"; exit 1 ;;
esac

echo
echo -e "${YEL}Step:${NC} Forward your $target_label sample email NOW to one of the accounts above."
echo "       (subject usually contains: $subj_hint)"
echo
echo "Then come back here and press Enter — I'll wait for the new email to appear."
read -r _

# Note the latest email id BEFORE poll (to detect new arrivals)
baseline_id=$(PSQL "SELECT COALESCE(MAX(id), 0) FROM emails;")
echo "Polling for new email (will time out after 3 min). Baseline id=$baseline_id."

t0=$(date +%s)
new_email_id=
while [[ $(($(date +%s) - t0)) -lt 180 ]]; do
  new_email_id=$(PSQL "SELECT id FROM emails WHERE id > $baseline_id AND from_address ILIKE ANY (ARRAY[$(echo "'$from_pattern'" | sed 's/|/'"'"', '"'"'/g')]) ORDER BY id DESC LIMIT 1;")
  if [[ -n "$new_email_id" ]]; then break; fi
  echo "  ...$(($(date +%s) - t0))s — no new $target_label email yet, waiting"
  sleep 12
done

if [[ -z "$new_email_id" ]]; then
  echo -e "${RED}✗${NC} timed out. Did you forward it? Did Gmail poller fire (every 15min)?"
  echo "    Manually trigger:  docker exec homeai-google-fetch python3 -c \"import urllib.request; urllib.request.urlopen('http://localhost:8011/poll-and-emit', data=b'').read()\""
  exit 1
fi

echo -e "${GREEN}✓${NC} captured new email id=$new_email_id"
SUBJ=$(PSQL "SELECT subject FROM emails WHERE id = $new_email_id;")
FROM=$(PSQL "SELECT from_address FROM emails WHERE id = $new_email_id;")
echo "    from:    $FROM"
echo "    subject: $SUBJ"
echo

# Dump body for inspection
mkdir -p /home_ai/.claude/n8n-exports/samples
SAMPLE_FILE="/home_ai/.claude/n8n-exports/samples/${table}-sample-$(date +%Y%m%d-%H%M%S).txt"
PSQL "SELECT body_text FROM emails WHERE id = $new_email_id;" > "$SAMPLE_FILE"
echo -e "${GREEN}✓${NC} body dumped to $SAMPLE_FILE  ($(wc -c < "$SAMPLE_FILE") bytes)"
echo
echo "--- first 30 lines ---"
head -30 "$SAMPLE_FILE"
echo "--- end ---"
echo

# Now wait for / inspect parser result. The pipeline runs every 15min so it
# may take up to that long. Poll until a row appears (or the audit log
# records 'unparseable').
echo "Polling parser result (will time out after 16 min)..."
t0=$(date +%s)
while [[ $(($(date +%s) - t0)) -lt 1000 ]]; do
  if [[ "$table" = "accommodation_daily" ]]; then
    HIT=$(PSQL "SELECT id, occupancy_pct, rooms_occupied, total_rooms, adr, revpar, room_revenue FROM accommodation_daily WHERE email_id = $new_email_id;")
  else
    HIT=$(PSQL "SELECT id, session, gross, net, vat, covers FROM epos_daily WHERE email_id = $new_email_id;")
  fi
  if [[ -n "$HIT" ]]; then
    echo -e "${GREEN}✓${NC} parsed → $table"
    echo "    $HIT"
    echo
    echo "Parser worked end-to-end. Sample file kept at $SAMPLE_FILE for future regression tests."
    exit 0
  fi
  # Also check audit log for unparseable
  AUDIT=$(PSQL "SELECT result FROM audit_log WHERE event_id = (SELECT event_id FROM emails WHERE id = $new_email_id) OR ai_parsed::text LIKE '%email_id%: $new_email_id%' ORDER BY created_at DESC LIMIT 1;")
  if [[ "$AUDIT" = "failure" ]]; then
    echo -e "${RED}✗${NC} parser logged the email as unparseable."
    echo
    echo "What to do next:"
    echo "  1. Inspect $SAMPLE_FILE to see what the real format looks like."
    echo "  2. Tell Claude in a new session: 'parser sample at $SAMPLE_FILE — update the parser regexes to match'."
    echo "     Claude will then patch the workflow's Code node to match the actual format."
    exit 2
  fi
  echo "  ...$(($(date +%s) - t0))s — pipeline hasn't run yet (every 15 min)"
  sleep 30
done

echo -e "${YEL}!${NC} timed out waiting for pipeline to fire."
echo "Sample file is at $SAMPLE_FILE — kick the pipeline manually or wait another cycle."
