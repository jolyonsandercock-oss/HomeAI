#!/bin/bash
# Verifies a Gmail OAuth Vault entry — prints lengths/email only, never values.
# Pipe runs on host (has jq); script file isolates user from paste-mangling.
set -euo pipefail

ACCOUNT="${1:-}"
if [[ -z "$ACCOUNT" ]]; then
  echo "Usage: $0 <account>   (personal1 | personal2 | workspace)"
  exit 1
fi

docker exec -e VAULT_TOKEN homeai-vault vault kv get -format=json "secret/gmail/$ACCOUNT" \
  | jq '.data.data | {
      id_len: (.oauth_client_id // "" | length),
      sec_len: (.oauth_client_secret // "" | length),
      tok_len: (.refresh_token // "" | length),
      email: (.email_address // "(missing)")
    }'
