#!/bin/bash
# tests/metis/test_08_nightly.sh — nightly orchestrator runs all stages without apply.
set -euo pipefail
out=$(bash "$(dirname "$0")/../../scripts/metis-nightly.sh" --dry-run 2>&1)
echo "$out" | grep -q "metis-observe" || { echo "FAIL: observe not run"; exit 1; }
echo "$out" | grep -q "metis-detect"  || { echo "FAIL: detect not run"; exit 1; }
echo "$out" | grep -qi "apply" && { echo "FAIL: apply must NOT run in nightly"; exit 1; }
echo "PASS"
