#!/bin/bash
# Store British Gas Lite portal creds in Vault for bg-lite-harvest.py.
# Prompts (no echo) so the password never hits shell history.
# Usage:  /home_ai/scripts/store-bg-lite-creds.sh
set -euo pipefail

read -rp "BG Lite username/email: " BG_USER
read -rsp "BG Lite password: " BG_PASS; echo

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
printf '{"username":"%s","password":"%s"}\n' "$BG_USER" "$BG_PASS" > "$TMP"

docker cp "$TMP" homeai-vault:/tmp/bg.json
docker exec -e VAULT_TOKEN homeai-vault vault kv put secret/britishgaslite @/tmp/bg.json
docker exec homeai-vault rm -f /tmp/bg.json

echo "✓ stored at secret/britishgaslite"
echo "Next: docker exec -e VAULT_TOKEN homeai-playwright python3 /home_ai/scripts/bg-lite-harvest.py --dry-run"
