#!/bin/bash
# U18-U21 unified selftest — pub board + telegram bot expansion + forensics + searxng
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

echo "=== U18-U21 — Pub board / Bot / Forensics / SearXNG ==="; echo

echo "--- U18 Pub Live Operations Board ---"
check "/pub returns 200"                "200" "$(http http://100.104.82.53/pub)"
check "/api/pub/snapshot returns 200"    "200" "$(http http://100.104.82.53/api/pub/snapshot)"
check "snapshot has today key"          "1" "$(curl -s http://100.104.82.53/api/pub/snapshot | grep -c '"today":')"
check "snapshot has week_calendar"        "1" "$(curl -s http://100.104.82.53/api/pub/snapshot | grep -c '"week_calendar":')"

echo
echo "--- U19 Telegram Bot Expansion ---"
check "V26 command_log table"            "1" "$(sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_name='command_log';")"
check "bot has /book in dispatch"        "1" "$(sql "SELECT (nodes::text LIKE '%/book%')::int FROM workflow_entity WHERE id='telegram-bot-v1';")"
check "bot has /epos in dispatch"        "1" "$(sql "SELECT (nodes::text LIKE '%/epos%')::int FROM workflow_entity WHERE id='telegram-bot-v1';")"
check "bot has Action: pause node"       "1" "$(sql "SELECT (nodes::text LIKE '%Action: pause%')::int FROM workflow_entity WHERE id='telegram-bot-v1';")"
check "bot has Route by kind switch"     "1" "$(sql "SELECT (nodes::text LIKE '%Route by kind%')::int FROM workflow_entity WHERE id='telegram-bot-v1';")"
check "bot recent fires successful"     "t" "$([ "$(sql "SELECT COUNT(*) FROM execution_entity WHERE \"workflowId\"='telegram-bot-v1' AND \"startedAt\" > NOW() - INTERVAL '5 minutes' AND status='success';")" -gt 0 ] && echo t || echo f)"

echo
echo "--- U20 Dead Letter Forensics ---"
check "/forensics returns 200"           "200" "$(http http://100.104.82.53/forensics)"
check "/api/forensics/dead-letters 200"  "200" "$(http http://100.104.82.53/api/forensics/dead-letters)"
check "DL list returns valid json"       "1" "$(curl -s http://100.104.82.53/api/forensics/dead-letters | grep -c '"items":')"

echo
echo "--- U21 SearXNG ---"
check "homeai-searxng running"           "1" "$(docker ps --filter name=homeai-searxng --filter status=running --format '{{.Names}}' | wc -l)"
check "/search returns 200/308"          "1" "$([ "$(http http://100.104.82.53/search)" -lt 400 ] && echo 1 || echo 0)"
check "JSON search API works"            "1" "$(curl -s 'http://100.104.82.53/search/search?q=cornwall&format=json' | grep -c '"results":')"
check "searxng image pinned"             "1" "$(grep -cE 'image: searxng/searxng:[0-9]+\.[0-9]+\.[0-9]+' /home_ai/docker-compose.yml)"

echo
echo "=========================================="
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
