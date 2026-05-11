#!/bin/bash
# U18-U25 unified selftest — all 8 sprints from the overnight session.
set -uo pipefail
PASS=0; FAIL=0
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
check() {
  if [ "$3" = "$2" ]; then
    echo -e "${GREEN}PASS${NC} $1 (=$3)"; PASS=$((PASS+1))
  else
    echo -e "${RED}FAIL${NC} $1 (expected=$2 got=$3)"; FAIL=$((FAIL+1))
  fi
}
sql() { docker exec homeai-postgres psql -U postgres -d homeai -tAc "$1" 2>&1; }
http() { curl -s -o /dev/null -w '%{http_code}' "$1"; }

echo "=== U18-U25 — Overnight #2 (Pub Board / Bot / Forensics / SearXNG / Playground / News / Anomaly) ==="; echo

echo "--- U18 Pub Board ---"
check "/pub returns 200"                "200" "$(http http://100.104.82.53/pub)"
check "/api/pub/snapshot returns 200"    "200" "$(http http://100.104.82.53/api/pub/snapshot)"

echo
echo "--- U19 Telegram bot expansion ---"
check "V26 command_log table"            "1"   "$(sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_name='command_log';")"
check "bot Route by kind switch"         "1"   "$(sql "SELECT (nodes::text LIKE '%Route by kind%')::int FROM workflow_entity WHERE id='telegram-bot-v1';")"

echo
echo "--- U20 Forensics UI ---"
check "/forensics returns 200"           "200" "$(http http://100.104.82.53/forensics)"
check "/api/forensics/dead-letters 200"  "200" "$(http http://100.104.82.53/api/forensics/dead-letters)"

echo
echo "--- U21 SearXNG ---"
check "searxng container running"         "1" "$(docker ps --filter name=homeai-searxng --filter status=running --format '{{.Names}}' | wc -l)"
check "JSON search API works"            "1" "$(curl -s 'http://100.104.82.53/search/search?q=cornwall&format=json' | grep -c '"results":')"

echo
echo "--- U22 Playground ---"
check "/playground returns 200"          "200" "$(http http://100.104.82.53/playground)"
check "classify endpoint works"          "1"   "$(curl -s -X POST -H 'Content-Type: application/json' -d '{"subject":"Payment Declined","body":"Your card was declined."}' http://100.104.82.53/api/playground/classify | grep -c 'final_category')"

echo
echo "--- U23 Cornwall briefing ---"
check "cornwall workflow active"         "t"   "$(sql "SELECT active FROM workflow_entity WHERE id='cornwall-news-briefing-v1';")"
check "schedule daily 07:00"             "1"   "$(sql "SELECT (nodes::text LIKE '%0 7 * * *%')::int FROM workflow_entity WHERE id='cornwall-news-briefing-v1';")"

echo
echo "--- U24 Enriched brief ---"
check "brief includes pub-status"        "1"   "$(sql "SELECT (nodes::text LIKE '%Fetch pub status%')::int FROM workflow_entity WHERE id='cornwall-news-briefing-v1';")"
check "brief format has Good morning"    "1"   "$(sql "SELECT (nodes::text LIKE '%Good morning%')::int FROM workflow_entity WHERE id='cornwall-news-briefing-v1';")"

echo
echo "--- U25 Pub anomaly alerter ---"
check "anomaly workflow active"          "t"   "$(sql "SELECT active FROM workflow_entity WHERE id='pub-anomaly-alerter-v1';")"
check "anomaly cron is hourly"           "1"   "$(sql "SELECT (nodes::text LIKE '%0 * * * *%')::int FROM workflow_entity WHERE id='pub-anomaly-alerter-v1';")"

echo
echo "=========================================="
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
