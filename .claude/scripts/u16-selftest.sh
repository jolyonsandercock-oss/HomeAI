#!/bin/bash
# U16 selftest — Caterbook attachment pipeline (text-only portion).
# PDF stages (A/B/C/E from plan) are deferred until google-fetch is restored.
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

echo "=== U16 — Caterbook Attachment Pipeline (text-only) ==="; echo

echo "--- D. V25 migration ---"
check "accommodation_bookings exists"   "1" "$(sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_name='accommodation_bookings';")"
check "RLS enabled"                      "t" "$(sql "SELECT relrowsecurity FROM pg_class WHERE relname='accommodation_bookings';")"
check "UNIQUE on (entity,source,ref)"   "1" "$(sql "SELECT COUNT(*) FROM pg_constraint WHERE conname='accommodation_bookings_uq';")"

echo
echo "--- F. caterbook-bookings-v1 workflow ---"
check "workflow active"                  "t" "$(sql "SELECT active FROM workflow_entity WHERE id='caterbook-bookings-v1';")"
check "workflow recent fire success"    "t" "$([ "$(sql "SELECT COUNT(*) FROM execution_entity WHERE \"workflowId\"='caterbook-bookings-v1' AND finished=true AND status='success';")" -gt 0 ] && echo t || echo f)"

echo
echo "--- G. Backfill: bookings parsed from existing 4 reservation emails ---"
check "bookings rows present (>=1)"      "t" "$([ "$(sql "SELECT COUNT(*) FROM accommodation_bookings;")" -ge 1 ] && echo t || echo f)"

echo
echo "--- H. notify-bridge fallback wired ---"
check "notify-bridge-v1 active"          "t" "$(sql "SELECT active FROM workflow_entity WHERE id='notify-bridge-v1';")"

echo
echo "--- I. PDF stages: deferred and clearly flagged ---"
check "google-fetch attachment endpoint code present"  "2" "$(grep -cE '@app\.get.*attachment' /home_ai/services/google-fetch/main.py)"
check "google-fetch deferred-state acknowledged"        "1" "$(grep -c 'google-fetch container stopped' /home_ai/services/build-dashboard/data/debt.yaml || echo 0)"

echo
echo "=========================================="
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
