#!/bin/bash
# tests/metis/test_08_nightly.sh — static orchestration check: nightly script
# invokes all required stages and does NOT invoke apply.
# Does NOT execute the pipeline against the live DB.
set -euo pipefail
S=scripts/metis-nightly.sh
for stage in metis-observe metis-categorise-detect metis-measure metis-digest; do
  grep -q "$stage" "$S" || { echo "FAIL: $S missing $stage"; exit 1; }
done
grep -q "metis-apply" "$S" && { echo "FAIL: nightly must NOT call apply"; exit 1; }
echo "PASS"
