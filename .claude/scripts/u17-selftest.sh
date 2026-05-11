#!/bin/bash
# U17 selftest — synthetic email harness + daily-digest polish.
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

echo "=== U17 — Synthetic Suite + Digest Polish ==="; echo

echo "--- A. Suite script present + executable ---"
check "synthetic-email-suite.sh exists"   "1" "$([ -f /home_ai/.claude/scripts/synthetic-email-suite.sh ] && echo 1 || echo 0)"
check "synthetic-email-suite.sh executable" "1" "$([ -x /home_ai/.claude/scripts/synthetic-email-suite.sh ] && echo 1 || echo 0)"

echo
echo "--- B. End-to-end suite run (live) ---"
SUITE_OUT=$(SKIP_TELEGRAM=1 bash /home_ai/.claude/scripts/synthetic-email-suite.sh 2>&1)
RESULT_LINE=$(echo "$SUITE_OUT" | grep -oE 'RESULT: [0-9]+ pass, [0-9]+ fail' | head -1)
PASS_COUNT=$(echo "$RESULT_LINE" | awk '{print $2}')
FAIL_COUNT=$(echo "$RESULT_LINE" | awk '{print $4}')
check "suite passes"           "7" "${PASS_COUNT:-0}"
check "suite has zero failures" "0" "${FAIL_COUNT:-99}"

# Verify cleanup actually worked
LEFTOVERS=$(docker exec -e PGOPTIONS='--row_security=off' homeai-postgres psql -U postgres -d homeai -tAc "SELECT COUNT(*) FROM emails WHERE gmail_message_id LIKE 'synthetic-suite-%';" 2>&1 | tr -d '[:space:]')
check "no synthetic emails left after run" "0" "${LEFTOVERS:-1}"

echo
echo "--- C. Cron line installed ---"
CRON_LINE=$(crontab -l 2>/dev/null | grep -c 'synthetic-email-suite.sh' || echo 0)
check "cron installed (1 line)" "1" "$CRON_LINE"

echo
echo "--- D. Daily-digest enriched ---"
check "digest SQL has epos_daily"           "1" "$(sql "SELECT (nodes::text LIKE '%epos_daily%')::int FROM workflow_entity WHERE id='daily-digest-v1';")"
check "digest SQL has accommodation_bookings" "1" "$(sql "SELECT (nodes::text LIKE '%accommodation_bookings%')::int FROM workflow_entity WHERE id='daily-digest-v1';")"
check "digest format has Today block"        "1" "$(sql "SELECT (nodes::text LIKE '%Today (pub)%')::int FROM workflow_entity WHERE id='daily-digest-v1';")"

echo
echo "=========================================="
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
