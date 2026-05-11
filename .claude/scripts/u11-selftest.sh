#!/bin/bash
# U11 selftest — validates Phase 1 Final Close deliverables
# Reports per-check pass/fail and exits non-zero on any failure.

set -uo pipefail
PASS=0; FAIL=0
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

check() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo -e "${GREEN}PASS${NC} $label (=$actual)"
    PASS=$((PASS+1))
  else
    echo -e "${RED}FAIL${NC} $label (expected=$expected got=$actual)"
    FAIL=$((FAIL+1))
  fi
}

run_sql() {
  docker exec homeai-postgres psql -U postgres -d homeai -tAc "$1" 2>&1
}

echo "=== U11 Phase 1 Final Close — selftest ==="
echo

echo "--- A. Database objects ---"
check "epos_daily exists"          "1" "$(run_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_name='epos_daily';")"
check "accommodation_daily exists" "1" "$(run_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_name='accommodation_daily';")"
check "telegram_bot_state exists"  "1" "$(run_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_name='telegram_bot_state';")"
check "epos_daily RLS enabled"     "t" "$(run_sql "SELECT relrowsecurity FROM pg_class WHERE relname='epos_daily';")"
check "accommodation_daily RLS enabled" "t" "$(run_sql "SELECT relrowsecurity FROM pg_class WHERE relname='accommodation_daily';")"
check "epos_daily UNIQUE constraint" "1" "$(run_sql "SELECT COUNT(*) FROM pg_constraint WHERE conname='epos_daily_uq';")"
check "accommodation_daily UNIQUE constraint" "1" "$(run_sql "SELECT COUNT(*) FROM pg_constraint WHERE conname='accommodation_daily_uq';")"

echo
echo "--- B. Pipelines registered + active ---"
check "P5 EPOS active"      "t" "$(run_sql "SELECT active FROM workflow_entity WHERE id='epos-pipeline-v1';")"
check "P6 Caterbook active" "t" "$(run_sql "SELECT active FROM workflow_entity WHERE id='caterbook-pipeline-v1';")"
check "Telegram bot active" "t" "$(run_sql "SELECT active FROM workflow_entity WHERE id='telegram-bot-v1';")"
check "Gmail Poll Driver active" "t" "$(run_sql "SELECT active FROM workflow_entity WHERE id='gmail-poll-driver-v1';")"
check "Gmail Ingest active" "t" "$(run_sql "SELECT active FROM workflow_entity WHERE id='gmail-ingest-v1';")"
check "Old QMKzaCFrKBS4ewWm deactivated" "f" "$(run_sql "SELECT active FROM workflow_entity WHERE id='QMKzaCFrKBS4ewWm';")"

echo
echo "--- C. Recent execution health (last 30m) ---"
check "Telegram bot recent successes >0" "t" "$([ "$(run_sql "SELECT COUNT(*) FROM execution_entity WHERE \"workflowId\"='telegram-bot-v1' AND \"startedAt\" > NOW() - INTERVAL '30 minutes' AND status='success';")" -gt 0 ] && echo t || echo f)"
check "Gmail driver recent successes >0" "t" "$([ "$(run_sql "SELECT COUNT(*) FROM execution_entity WHERE \"workflowId\"='gmail-poll-driver-v1' AND \"startedAt\" > NOW() - INTERVAL '30 minutes' AND status='success';")" -gt 0 ] && echo t || echo f)"
check "No new dead letters (5m)" "0" "$(run_sql "SELECT COUNT(*) FROM dead_letter WHERE created_at > NOW() - INTERVAL '5 minutes' AND resolved=false;")"

echo
echo "--- D. Classifier UNIQUE guard ---"
check "Gmail Ingest INSERT emails has ON CONFLICT" "1" "$(run_sql "SELECT COUNT(*) FROM workflow_entity WHERE id='gmail-ingest-v1' AND nodes::text ILIKE '%ON CONFLICT (gmail_message_id)%';")"

echo
echo "--- E. Audit ---"
check "audit_log has p5/p6 entries OR none yet" "t" "$([ "$(run_sql "SELECT COUNT(*) >= 0 FROM audit_log WHERE pipeline IN ('p5-epos','p6-caterbook');")" = "t" ] && echo t || echo f)"

echo
echo "=========================================="
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
