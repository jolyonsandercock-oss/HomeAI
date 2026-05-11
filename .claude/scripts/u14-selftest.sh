#!/bin/bash
# U14 selftest — validates tech-debt sweep deliverables.
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

run_sql() {
  docker exec homeai-postgres psql -U postgres -d homeai -tAc "$1" 2>&1
}

echo "=== U14 Tech Debt Sweep — selftest ==="
echo

echo "--- A. Classifier patches in production ---"
check "INVOICE_HEURISTIC_v1 in workflow" "1" "$(run_sql "SELECT (nodes::text LIKE '%INVOICE_HEURISTIC_v1%')::int FROM workflow_entity WHERE id='gmail-ingest-v1';")"
check "New prompt: RECEIPT, REFUND clause" "1" "$(run_sql "SELECT (nodes::text LIKE '%RECEIPT, REFUND%')::int FROM workflow_entity WHERE id='gmail-ingest-v1';")"
check "ai_category uses finalCategory"     "1" "$(run_sql "SELECT (nodes::text LIKE '%ai_category%finalCategory%')::int FROM workflow_entity WHERE id='gmail-ingest-v1';")"
check "Workflow still active"              "t" "$(run_sql "SELECT active FROM workflow_entity WHERE id='gmail-ingest-v1';")"

echo
echo "--- B. Vault telemetry config staged ---"
check "vault.hcl has unauthenticated_metrics_access" "1" "$(grep -c 'unauthenticated_metrics_access' /home_ai/security/vault-config/vault.hcl)"
check "vault.hcl has top-level telemetry block"      "1" "$(grep -c '^telemetry {' /home_ai/security/vault-config/vault.hcl)"
check "prometheus.yml notes the staged change"        "1" "$(grep -c 'U14' /home_ai/monitoring/prometheus.yml)"

echo
echo "--- C. Heuristic synthetic tests ---"
HOUT=$(node /tmp/heuristic-test.js 2>/dev/null | grep -c '^PASS' || echo 0)
check "5/5 heuristic cases pass" "5" "$HOUT"

echo
echo "--- D. Pipeline health post-restart ---"
check "Telegram bot recent successes >0" "t" "$([ "$(run_sql "SELECT COUNT(*) FROM execution_entity WHERE \"workflowId\"='telegram-bot-v1' AND \"startedAt\" > NOW() - INTERVAL '5 minutes' AND status='success';")" -gt 0 ] && echo t || echo f)"
check "No new dead letters (5m)"          "0" "$(run_sql "SELECT COUNT(*) FROM dead_letter WHERE created_at > NOW() - INTERVAL '5 minutes' AND resolved=false;")"

echo
echo "=========================================="
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
