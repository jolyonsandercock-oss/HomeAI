#!/bin/bash
# u268-britishgas-portal.sh — scrape British Gas Business portal bills -> vendor_invoice_inbox.
# Idempotent (ON CONFLICT on idempotency_key). Creds in Vault secret/britishgas.
# Cron candidate: monthly (BG bills are monthly). Login is human-paced; single attempt.
set -euo pipefail
VT=$(docker inspect homeai-bot-responder --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
BG_USER=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=username secret/britishgas)
BG_PASS=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=password secret/britishgas)
# 1. scrape (download bill PDFs inside playwright)
docker exec homeai-playwright sh -c "rm -rf /tmp/bg_bills"
docker cp /home_ai/scripts/u268-britishgas-scrape.py homeai-playwright:/tmp/scrape.py
docker exec -e BG_USER="$BG_USER" -e BG_PASS="$BG_PASS" homeai-playwright python3 /tmp/scrape.py
# 2. copy PDFs out to host + into bot-responder
mkdir -p /home_ai/storage/bg_bills
docker cp homeai-playwright:/tmp/bg_bills/. /home_ai/storage/bg_bills/ 2>/dev/null || true
docker exec homeai-bot-responder sh -c "rm -rf /tmp/bg_bills && mkdir -p /tmp/bg_bills"
docker cp /home_ai/storage/bg_bills/. homeai-bot-responder:/tmp/bg_bills/
# 3. extract + ingest -> vendor_invoice_inbox
docker cp /home_ai/scripts/u268-britishgas-ingest.py homeai-bot-responder:/tmp/ingest.py
docker exec -e PYTHONPATH=/app homeai-bot-responder python3 /tmp/ingest.py
# cleanup
docker exec homeai-playwright sh -c "rm -rf /tmp/bg_bills /tmp/scrape.py" 2>/dev/null || true
docker exec homeai-bot-responder sh -c "rm -rf /tmp/bg_bills /tmp/ingest.py" 2>/dev/null || true
