#!/bin/bash
# tests/metis/test_07_digest.sh — verify metis-digest.sh --dry-run output.
set -euo pipefail
out=$(bash "$(dirname "$0")/../../scripts/metis-digest.sh" --dry-run)
echo "$out" | grep -q "Metis proposals" || { echo "FAIL: missing digest header"; exit 1; }
echo "PASS"
