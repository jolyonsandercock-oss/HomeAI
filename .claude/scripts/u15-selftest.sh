#!/bin/bash
# U15 selftest — validates Master Router Intelligence deliverables.
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

echo "=== U15 Master Router Intelligence — selftest ==="; echo

echo "--- A. V24 migration ---"
check "recover_stale_leases_v2 exists"  "1" "$(sql "SELECT COUNT(*) FROM pg_proc WHERE proname='recover_stale_leases_v2';")"
check "v1 still callable (rollback)"     "1" "$(sql "SELECT COUNT(*) FROM pg_proc WHERE proname='recover_stale_leases';")"

echo
echo "--- B. Master-router calls v2 ---"
check "master-router uses v2"            "1" "$(sql "SELECT (nodes::text LIKE '%recover_stale_leases_v2%')::int FROM workflow_entity WHERE id='test-master-router';")"
check "master-router still active"        "t" "$(sql "SELECT active FROM workflow_entity WHERE id='test-master-router';")"

echo
echo "--- C. Dead-letter sweeper ---"
check "sweeper workflow active"           "t" "$(sql "SELECT active FROM workflow_entity WHERE id='dead-letter-sweeper-v1';")"

echo
echo "--- D. Regression test passes ---"
docker cp /home_ai/postgres/tests/u15-regression.sql homeai-postgres:/tmp/u15-regression.sql >/dev/null 2>&1
REG_OUT=$(docker exec -i homeai-postgres psql -U postgres -d homeai -f /tmp/u15-regression.sql 2>&1 | grep -oE 'PASS|FAIL' | sort | uniq -c | tr -s ' ')
PASSES=$(echo "$REG_OUT" | grep PASS | awk '{print $1}')
FAILS=$(echo "$REG_OUT" | grep FAIL | awk '{print $1}')
check "regression passes"                "5" "${PASSES:-0}"
check "regression failures"              "0" "${FAILS:-0}"

echo
echo "--- E. Live invocation: v2 ran ok within last hour ---"
check "v2 runs from master-router"       "t" "$([ "$(sql "SELECT COUNT(*) FROM execution_entity WHERE \"workflowId\"='test-master-router' AND \"startedAt\" > NOW() - INTERVAL '5 minutes' AND status='success';")" -gt 0 ] && echo t || echo f)"

echo
echo "=========================================="
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
