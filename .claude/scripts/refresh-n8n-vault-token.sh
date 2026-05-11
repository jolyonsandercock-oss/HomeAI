#!/bin/bash
# Reloads n8n-policy in Vault from /vault/policies/n8n-policy.hcl, then issues
# a fresh long-lived Vault token bound to that policy. Prints the token to
# THIS terminal only — copy it into n8n UI → Credentials → vault-token-header
# → header value field. Do NOT paste the token into chat or any other context.
set -euo pipefail

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  echo "✗ VAULT_TOKEN must be set (root or one with sudo on policies + token create)"
  exit 1
fi

echo "1/3 reloading n8n-policy from disk..."
docker exec -e VAULT_TOKEN homeai-vault \
  vault policy write n8n-policy /vault/policies/n8n-policy.hcl >/dev/null
echo "    ✓ policy reloaded"

echo "2/3 confirming policy includes secret/data/gmail/*..."
GMAIL_OK=$(docker exec -e VAULT_TOKEN homeai-vault vault policy read n8n-policy | grep -c 'secret/data/gmail' || true)
if [[ "$GMAIL_OK" -lt 1 ]]; then
  echo "    ✗ policy is missing gmail paths — check n8n-policy.hcl"
  exit 1
fi
echo "    ✓ gmail paths present"

echo "3/3 issuing fresh token (30-day TTL, renewable)..."
TOKEN=$(docker exec -e VAULT_TOKEN homeai-vault \
  vault token create -policy=n8n-policy -ttl=720h -renewable=true -format=json \
  | jq -r '.auth.client_token')

if [[ -z "$TOKEN" ]]; then
  echo "    ✗ token creation returned empty"
  exit 1
fi

cat <<EOF

════════════════════════════════════════════════════════════════
NEW VAULT TOKEN — copy this to n8n UI:

    $TOKEN

════════════════════════════════════════════════════════════════

Steps:
  1. Browser: http://100.104.82.53:5678
  2. Top-left → Credentials → vault-token-header
  3. Header name field: X-Vault-Token  (probably already set — leave it)
  4. Header value field: paste the token above
  5. Save
  6. In your terminal: docker restart homeai-n8n

Then we wait for the next 15-min cron tick on Gmail Ingest.
DO NOT paste this token into chat or any other context.
EOF
unset TOKEN
