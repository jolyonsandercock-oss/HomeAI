#!/usr/bin/env bash
# u-invoice-line-sweep.sh — daily forward sweep: extract LINE ITEMS for any new
# target-supplier invoices into vendor_invoice_lines (pdfplumber + local qwen2.5:72b,
# cross-foot gated). The extractor skips invoices that already have lines, so this
# is forward-only by construction — only genuinely new invoices cost GPU time.
# Off the n8n event path. Runs after tonight's backfill, so no GPU contention.
#
#   u-invoice-line-sweep.sh [year]   # default 2026
set -uo pipefail
SCRIPT=/home_ai/scripts/invoice-line-extract.py
LOGDIR=/home_ai/logs; mkdir -p "$LOGDIR"; LOG="$LOGDIR/invoice-line-sweep.log"
YEAR="${1:-2026}"
VT=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
{
  echo "=== $(date -Is) invoice LINE sweep (YEAR=$YEAR) ==="
  docker exec -i -e VAULT_TOKEN="$VT" -e MODE=apply -e IDS=targets -e YEAR="$YEAR" -e LIMIT=600 \
    -e OLLAMA_MODEL=gemma4-doc:latest homeai-bot-responder python3 < "$SCRIPT"
  echo "=== $(date -Is) done (rc=$?) ==="
} >> "$LOG" 2>&1
