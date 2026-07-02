#!/bin/bash
# scripts/metis-nightly.sh — SHADOW-MODE loop: observe→detect→measure→digest.
# Deliberately excludes apply (human approves via dashboard; apply runs separately).
# --no-send: run the pipeline but don't send the Telegram digest (observe/detect/measure still write).
set -euo pipefail
NO_SEND=""
[ "${1:-}" = "--no-send" ] && NO_SEND="--dry-run"
cd /home_ai
echo "metis-observe"; bash scripts/metis-observe.sh || true
echo "metis-detect";  bash scripts/metis-categorise-detect.sh || true
echo "metis-measure"; bash scripts/metis-measure.sh || true
bash scripts/metis-digest.sh ${NO_SEND} 10
