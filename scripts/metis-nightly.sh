#!/bin/bash
# scripts/metis-nightly.sh — SHADOW-MODE loop: observe→detect→measure→digest.
# Deliberately excludes apply (human approves via dashboard; apply runs separately).
set -uo pipefail
DRY=""
[ "${1:-}" = "--dry-run" ] && DRY="--dry-run"
cd /home_ai
echo "metis-observe"; bash scripts/metis-observe.sh || true
echo "metis-detect";  bash scripts/metis-categorise-detect.sh || true
echo "metis-measure"; bash scripts/metis-measure.sh || true
bash scripts/metis-digest.sh ${DRY} 10
