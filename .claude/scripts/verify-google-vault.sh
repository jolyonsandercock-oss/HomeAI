#!/bin/bash
# Verifies Stage A Vault writes and prints the values needed for DWD setup.
# Reads VAULT_TOKEN from env. Never prints secret values — only field counts
# and non-secret extracted fields (SA email + numeric client_id).
set -euo pipefail

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  echo "✗ VAULT_TOKEN not set. Run: export VAULT_TOKEN='<your-token>'  first."
  exit 1
fi

echo "── Verifying secret/google/oauth-client ──"
OAUTH_JSON=$(docker exec -e VAULT_TOKEN homeai-vault vault kv get -format=json secret/google/oauth-client 2>&1 || true)

if echo "$OAUTH_JSON" | grep -q '"errors"'; then
  echo "  ✗ NOT FOUND or no permission. Output:"
  echo "$OAUTH_JSON" | head -3
else
  HAS_CID=$(echo "$OAUTH_JSON" | grep -c '"client_id"' || true)
  HAS_SEC=$(echo "$OAUTH_JSON" | grep -c '"client_secret"' || true)
  echo "  client_id:     $([ "$HAS_CID" -ge 1 ] && echo present || echo MISSING)"
  echo "  client_secret: $([ "$HAS_SEC" -ge 1 ] && echo present || echo MISSING)"
fi

echo
echo "── Verifying secret/google/sa-malthouse ──"
SA_JSON=$(docker exec -e VAULT_TOKEN homeai-vault vault kv get -format=json secret/google/sa-malthouse 2>&1 || true)

if echo "$SA_JSON" | grep -q '"errors"'; then
  echo "  ✗ NOT FOUND or no permission. Output:"
  echo "$SA_JSON" | head -3
  exit 1
fi

HAS_KEY=$(echo "$SA_JSON" | grep -c '"json_key"' || true)
echo "  json_key:      $([ "$HAS_KEY" -ge 1 ] && echo present || echo MISSING)"

if [[ "$HAS_KEY" -lt 1 ]]; then
  echo "  ✗ aborting — JSON key field missing"
  exit 1
fi

echo
echo "── Extracting non-secret fields from SA JSON ──"
# The field lives nested as data.data.json_key (a string of the entire JSON file).
# Pull it out with python — robust against any escaping.
SA_BLOB=$(docker exec -e VAULT_TOKEN homeai-vault vault kv get -field=json_key secret/google/sa-malthouse 2>&1)

SA_EMAIL=$(printf '%s' "$SA_BLOB" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("client_email",""))' 2>&1)
SA_CID=$(printf '%s' "$SA_BLOB" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("client_id",""))' 2>&1)
SA_PROJECT=$(printf '%s' "$SA_BLOB" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("project_id",""))' 2>&1)

echo "  SA email:        $SA_EMAIL"
echo "  SA numeric ID:   $SA_CID    (use this in admin.google.com DWD step)"
echo "  Project ID:      $SA_PROJECT"
echo
echo "✓ Verification complete. Paste the 3 lines above into chat — all are non-secret."
