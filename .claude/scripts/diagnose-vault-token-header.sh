#!/bin/bash
# Diagnoses the n8n vault-token-header credential. Prints PASS/FAIL signals
# only — never the token value itself.
set -euo pipefail

CRED_ID="0wPA4DCDuehPC9Mf"

# 1. Extract the credential's current token (lives in container only)
docker exec homeai-n8n n8n export:credentials \
  --id="$CRED_ID" --decrypted --output=/tmp/c.json >/dev/null 2>&1
docker cp homeai-n8n:/tmp/c.json /tmp/c.json >/dev/null
docker exec homeai-n8n rm /tmp/c.json

# Header value format may be "Bearer xxx" or just "xxx"
TOKEN_VALUE=$(jq -r '.[0].data.value // .[0].data.headerValue // empty' /tmp/c.json)
HEADER_NAME=$(jq -r '.[0].data.name // .[0].data.headerName // empty' /tmp/c.json)
TOKEN=${TOKEN_VALUE#Bearer }
TOKEN=${TOKEN# }
LEN=${#TOKEN}
rm /tmp/c.json

echo "Header name: $HEADER_NAME"
echo "Token length (chars): $LEN"
echo

# 2. Look up the token's accessor + policies (output structure only, no token)
LOOKUP=$(docker exec -e VAULT_TOKEN="$TOKEN" homeai-vault \
  vault token lookup -format=json 2>&1) || {
    echo "✗ token lookup FAILED — token may be invalid/revoked"
    echo "$LOOKUP" | head -3
    exit 1
  }

POLICIES=$(echo "$LOOKUP" | jq -r '.data.policies | join(",")')
TTL=$(echo "$LOOKUP" | jq -r '.data.ttl')
echo "Policies attached: $POLICIES"
echo "Remaining TTL (s): $TTL"
echo

# 3. Try reading secret/gmail/personal1 with this token
GMAIL=$(docker exec -e VAULT_TOKEN="$TOKEN" homeai-vault \
  vault kv get -format=json secret/gmail/personal1 2>&1) || true
if echo "$GMAIL" | grep -q '"data"'; then
  echo "✓ token CAN read secret/gmail/personal1"
else
  echo "✗ token CANNOT read secret/gmail/personal1:"
  echo "$GMAIL" | head -3
fi
unset TOKEN TOKEN_VALUE LOOKUP GMAIL
