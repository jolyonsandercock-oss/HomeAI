#!/bin/bash
# U13 selftest — validates all U13 deliverables.
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

echo "=== U13 — selftest ==="
echo

echo "--- A. Image audit workflow ---"
check "image-audit-monthly-v1 active" "t" "$(docker exec homeai-postgres psql -U postgres -d homeai -tAc "SELECT active FROM workflow_entity WHERE id='image-audit-monthly-v1';" 2>/dev/null)"

echo
echo "--- B. DR scripts shellcheck-clean ---"
SC_OUT=$(docker run --rm -v /home_ai:/repo:ro koalaman/shellcheck:stable \
  /repo/scripts/backup-all.sh \
  /repo/scripts/backup-nightly.sh \
  /repo/scripts/restore.sh \
  /repo/scripts/bootstrap.sh 2>&1)
check "DR scripts shellcheck pass" "" "$SC_OUT"

echo
echo "--- C/D/E. User-runnable scripts present + executable ---"
for s in u13-mount-nas u13-install-hooks u13-bootstrap-auto-unseal u13-vault-unseal; do
  P="/home_ai/.claude/scripts/${s}.sh"
  check "$s.sh exists"     "1" "$([ -f "$P" ] && echo 1 || echo 0)"
  check "$s.sh executable" "1" "$([ -x "$P" ] && echo 1 || echo 0)"
done

echo
echo "--- C/D/E. User-runnable scripts shellcheck-clean ---"
SC_USER=$(docker run --rm -v /home_ai:/repo:ro koalaman/shellcheck:stable \
  /repo/.claude/scripts/u13-mount-nas.sh \
  /repo/.claude/scripts/u13-install-hooks.sh \
  /repo/.claude/scripts/u13-bootstrap-auto-unseal.sh \
  /repo/.claude/scripts/u13-vault-unseal.sh 2>&1)
check "user scripts shellcheck pass" "" "$SC_USER"

echo
echo "--- D. Hook scripts block known-bad inputs ---"
NS_OUT=$(echo '{"tool_input":{"file_path":"/tmp/x.env"}}' | /home_ai/.claude/hooks/no-secrets-in-files.sh 2>&1; echo "exit=$?")
check "no-secrets blocks .env (exit 2)" "exit=2" "$(echo "$NS_OUT" | tail -1)"
SQL_OUT=$(echo '{"tool_input":{"file_path":"/tmp/x.sql","content":"INSERT INTO events (event_type) VALUES ('"'"'foo'"'"');"}}' | /home_ai/.claude/hooks/sql-rules.sh 2>&1; echo "exit=$?")
check "sql-rules blocks unsigned events (exit 2)" "exit=2" "$(echo "$SQL_OUT" | tail -1)"

echo
echo "--- F. n8n image-audit workflow JSON well-formed ---"
check "image-audit JSON parses" "1" "$(jq -e . /home_ai/.claude/n8n-exports/image-audit-monthly-v1.json >/dev/null 2>&1 && echo 1 || echo 0)"

echo
echo "=========================================="
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
