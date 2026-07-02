#!/bin/bash
# u95-harvest-cron.sh — incremental invoice-email harvest into vendor_invoice_inbox.
#
# Wraps scripts/u95-harvest-all-invoices.py for scheduled use. Pipes the
# harvester into homeai-bot-responder over stdin; the container already has
# VAULT_TOKEN + PG_DSN in its env, so nothing sensitive is passed on the CLI.
# Idempotent: u95 dedupes on idempotency_key / source_email_id before insert.
# The hourly u35 cron extracts whatever this ingests.
#
# Usage: u95-harvest-cron.sh [days_back]   (default 3 for daily incremental)
set -euo pipefail
DAYS="${1:-3}"
docker exec -i homeai-bot-responder python3 - "$DAYS" < /home_ai/scripts/u95-harvest-all-invoices.py
