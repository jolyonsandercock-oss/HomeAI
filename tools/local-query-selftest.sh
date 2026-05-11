#!/usr/bin/env bash
# §BLF-4 Self-test — validates local-query.sh end-to-end
# Run before Step 9b. All sections must PASS.

set -euo pipefail
TOOL="$(dirname "$0")/local-query.sh"
PASS=0; FAIL=0

run_test() {
  local name="$1"; local expected_pattern="$2"; local actual="$3"
  if echo "$actual" | grep -qi "$expected_pattern"; then
    echo "  ✅ PASS — $name"
    ((PASS++))
  else
    echo "  ❌ FAIL — $name"
    echo "     Expected pattern: $expected_pattern"
    echo "     Got: $actual"
    ((FAIL++))
  fi
}

echo ""
echo "=== §BLF-4 LOCAL-QUERY SELF-TEST ==="
echo "Tool: $TOOL"
echo "Model: ${LOCAL_QUERY_MODEL:-qwen2.5:7b}"
echo "Ollama: ${OLLAMA_URL:-http://localhost:11434}"
echo ""

# Test 1 — Ollama reachability
echo "[1/5] Ollama reachability"
if curl -sf --max-time 3 "${OLLAMA_URL:-http://localhost:11434}/api/tags" > /dev/null 2>&1; then
  echo "  ✅ PASS — Ollama responding"
  ((PASS++))
else
  echo "  ❌ FAIL — Ollama not reachable"
  ((FAIL++))
fi

# Test 2 — Model is available
echo "[2/5] Model availability"
MODEL="${LOCAL_QUERY_MODEL:-qwen2.5:7b}"
MODEL_CHECK=$(curl -sf "${OLLAMA_URL:-http://localhost:11434}/api/tags" | jq -r '.models[].name' 2>/dev/null || echo "")
if echo "$MODEL_CHECK" | grep -q "$MODEL"; then
  echo "  ✅ PASS — ${MODEL} found"
  ((PASS++))
else
  echo "  ❌ FAIL — ${MODEL} not in model list"
  echo "     Available: $MODEL_CHECK"
  ((FAIL++))
fi

# Test 3 — Basic factual question (no file context)
echo "[3/5] Basic factual response"
RESP3=$("$TOOL" "What is 2 + 2? Reply with only the number." 2>&1 || true)
run_test "arithmetic response" "4" "$RESP3"

# Test 4 — File pipe mode (column existence check — core use case)
echo "[4/5] File pipe / column existence check"
TMPFILE=$(mktemp /tmp/blf-test-XXXX.sql)
cat > "$TMPFILE" <<'SQL'
CREATE TABLE model_scan_log (
    id SERIAL PRIMARY KEY,
    scan_source VARCHAR(64) NOT NULL,
    scanned_at TIMESTAMPTZ DEFAULT NOW(),
    models_found INTEGER DEFAULT 0
);
SQL
RESP4=$("$TOOL" "Does a column named scan_source exist in the model_scan_log table? Answer yes or no." < "$TMPFILE" 2>&1 || true)
run_test "column existence detection" "yes" "$RESP4"
rm -f "$TMPFILE"

# Test 5 — Negative case (column that does not exist)
echo "[5/5] Negative case — column that does not exist"
TMPFILE2=$(mktemp /tmp/blf-test-XXXX.sql)
cat > "$TMPFILE2" <<'SQL'
CREATE TABLE model_scan_log (
    id SERIAL PRIMARY KEY,
    scanned_at TIMESTAMPTZ DEFAULT NOW()
);
SQL
RESP5=$("$TOOL" "Does a column named scan_source exist in the model_scan_log table? Answer yes or no." < "$TMPFILE2" 2>&1 || true)
run_test "negative column detection" "no" "$RESP5"
rm -f "$TMPFILE2"

# Summary
echo ""
echo "=== RESULT: ${PASS} passed, ${FAIL} failed ==="
if [[ $FAIL -eq 0 ]]; then
  echo "✅ §BLF-4 SELF-TEST PASSED — local-query.sh is operational"
  echo "   Record this output in the Step 9b plan log before entering Plan Mode."
  exit 0
else
  echo "❌ §BLF-4 SELF-TEST FAILED — resolve failures before proceeding"
  exit 1
fi
