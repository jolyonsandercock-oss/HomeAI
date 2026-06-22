#!/bin/bash
# invoice-line-batch-chunk.sh — process ONE chunk of the invoice line backfill
# Called by cron every 2 hours with a different CHUNK_ID each time.
# Each chunk runs the main u-invoice-line-sweep.sh with a 60-minute timeout,
# overlap-protected via flock.
#
# Usage: bash invoice-line-batch-chunk.sh <CHUNK_ID> <TOTAL_CHUNKS>
#   CHUNK_ID:     0-based chunk number (e.g. 0,1,2,...11 for 12 total)
#   TOTAL_CHUNKS: total number of chunks

set -euo pipefail

CHUNK="${1:-0}"
TOTAL="${2:-12}"
LOCKFILE="/tmp/invoice-line-backfill.lock"
LOG="/home_ai/logs/u-invoice-line-sweep.cron.log"

# Overlap guard — only one chunk runs at a time
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    echo "$(date -Is) chunk=${CHUNK}/${TOTAL} SKIPPED — another chunk is running" | tee -a "$LOG"
    exit 0
fi

START=$(date +%s)
echo "=== $(date -Is) BATCH CHUNK ${CHUNK}/${TOTAL} START ===" | tee -a "$LOG"

# Run the main sweep with 60-min timeout
timeout 3600 bash /home_ai/scripts/u-invoice-line-sweep.sh 2026 >> "$LOG" 2>&1
RC=$?

ELAPSED=$(($(date +%s) - START))
echo "=== $(date -Is) CHUNK ${CHUNK}/${TOTAL} DONE rc=${RC} elapsed=${ELAPSED}s ===" | tee -a "$LOG"

exit $RC
