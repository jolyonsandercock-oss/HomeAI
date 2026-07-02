#!/usr/bin/env bash
# u-invoice-line-sweep.sh — daily forward sweep: extract LINE ITEMS for any new
# target-supplier invoices into vendor_invoice_lines (pdfplumber + local qwen2.5:72b,
# cross-foot gated). The extractor skips invoices that already have lines, so this
# is forward-only by construction — only genuinely new invoices cost GPU time.

# flock protection — don't run if a batch chunk is already extracting
exec 200>/tmp/invoice-line-backfill.lock
if ! flock -n 200; then
    echo "$(date -Is) SKIPPED — another extraction is running" | tee -a /home_ai/logs/u-invoice-line-sweep.cron.log
    exit 0
fi
# Off the n8n event path. Runs after tonight's backfill, so no GPU contention.
#
#   u-invoice-line-sweep.sh [year]   # default 2026
set -euo pipefail
echo "$(date -Is) u-invoice-line-sweep heartbeat (started)"  # liveness → cron log; START not END because line-extraction can run long (72B over the backlog)
SCRIPT=/home_ai/scripts/invoice-line-extract.py
LOGDIR=/home_ai/logs; mkdir -p "$LOGDIR"; LOG="$LOGDIR/invoice-line-sweep.log"
YEAR="${1:-2026}"
VT=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
{
  echo "=== $(date -Is) invoice LINE sweep (YEAR=$YEAR) ==="
  # Capture the real exit code via && / || — under set -e, a plain command here
  # would abort the brace group before the "done" line (or the exit below) ever ran.
  docker exec -i -e VAULT_TOKEN="$VT" -e MODE=apply -e IDS=targets -e YEAR="$YEAR" -e LIMIT=600 \
    -e OLLAMA_MODEL=gemma4-doc:latest homeai-bot-responder python3 < "$SCRIPT" && rc=0 || rc=$?
  echo "=== $(date -Is) done (rc=$rc) ==="
} >> "$LOG" 2>&1
exit $rc
