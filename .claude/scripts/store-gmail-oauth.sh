#!/bin/bash
# Stores Gmail OAuth credentials in Vault. Prompts for each value (typed
# silently for the secret values). Usage:
#   bash /home_ai/.claude/scripts/store-gmail-oauth.sh personal1
set -euo pipefail

ACCOUNT="${1:-}"
if [[ -z "$ACCOUNT" ]]; then
  echo "Usage: $0 <account>   (e.g. personal1, personal2, workspace)"
  exit 1
fi

if ! [[ "$ACCOUNT" =~ ^(personal1|personal2|workspace)$ ]]; then
  echo "Error: account must be personal1, personal2, or workspace"
  exit 1
fi

read -p "email address (e.g. you@gmail.com): " EMA
read -p "client_id (.apps.googleusercontent.com): " CID
read -rsp "client_secret (silent): " CSE
printf '\n'
read -rsp "refresh_token (silent, starts 1//): " RTK
printf '\n'

if [[ -z "$EMA" || -z "$CID" || -z "$CSE" || -z "$RTK" ]]; then
  echo "✗ all four values required — aborting"
  exit 1
fi

if ! [[ "$RTK" == 1//* ]]; then
  echo "⚠ refresh_token doesn't start with '1//' — typical Google format. Continue anyway? (y/N)"
  read -r confirm
  [[ "$confirm" == "y" ]] || exit 1
fi

docker exec -e VAULT_TOKEN -e P_EMA="$EMA" -e P_CID="$CID" -e P_CSE="$CSE" -e P_RTK="$RTK" \
  homeai-vault sh -c '
vault kv put secret/gmail/'"$ACCOUNT"' \
  email_address="$P_EMA" \
  oauth_client_id="$P_CID" \
  oauth_client_secret="$P_CSE" \
  refresh_token="$P_RTK"
'

unset EMA CID CSE RTK
echo
echo "✓ stored at secret/gmail/$ACCOUNT"
