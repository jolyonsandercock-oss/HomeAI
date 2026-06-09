#!/bin/bash
# u271-resolve-invoices.sh — forward-only counterparty resolver sweep over new invoices.
#
# Calls home_ai.resolve_new_invoices(), which acts per the resolver.mode flag:
#   shadow  -> dry-run metrics only (no attribution)
#   review  -> confident invoices attributed; abstains pushed to the review queue
#   enforce -> confident invoices attributed; abstains dropped silently
#
# Forward-only via resolver.invoice_watermark_id; idempotent (attributed / queued
# rows are skipped). Safe to run frequently. Activated in review mode 2026-06-09.
# Cron: every 30 min.
set -uo pipefail

OUT=$(docker exec -i homeai-postgres psql -U postgres -d homeai -tA \
        -c "SELECT home_ai.resolve_new_invoices(500);" 2>&1)
rc=$?
echo "$(date -Is) rc=$rc $OUT"
exit $rc
