#!/usr/bin/env bash
# u-invoice-pdf-date-sweep.sh — forward-only daily sweep that corrects each newly
# ingested invoice's invoice_date from its PDF (pdfplumber text -> local gemma4-doc),
# confidence-gated and idempotent (re-confirming a correct date is a no-op).
#
# WHY a sweep, not an n8n change: the invoice writer (P2) lives in the fragile n8n
# event pipeline (claim_event_batch / master-router / DL-flood history). This stays
# OFF that path — it post-processes new invoices, so it can never flood or break
# live capture. Mirrors the other inbox sweeps (Dojo/Caterbook/NatWest).
#
# invoice_date MUST come from the PDF, never the email received-date: invoices get
# resent/forwarded months late and post-dating is legitimate (see the memory). The
# extractor flags anything it can't verify (no-PDF / unparseable) rather than guess.
#
#   u-invoice-pdf-date-sweep.sh [hours]   # default 26h window (overlap-tolerant)
set -uo pipefail
SCRIPT=/home_ai/scripts/invoice-pdf-date-extract.py
LOGDIR=/home_ai/logs; mkdir -p "$LOGDIR"; LOG="$LOGDIR/invoice-pdf-date-sweep.log"
HOURS="${1:-26}"
VT=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
{
  echo "=== $(date -Is) invoice PDF-date sweep (HOURS=$HOURS) ==="
  docker exec -i -e VAULT_TOKEN="$VT" -e MODE=apply -e IDS=recent -e HOURS="$HOURS" \
    -e OLLAMA_MODEL=gemma4-doc:latest -e PYTHONUNBUFFERED=1 \
    homeai-bot-responder python3 < "$SCRIPT"
  echo "=== $(date -Is) done (rc=$?) ==="
} >> "$LOG" 2>&1
