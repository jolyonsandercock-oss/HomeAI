#!/bin/bash
# Stores Google OAuth client + service account JSON in Vault.
# Same pattern as store-gmail-oauth.sh: env-var passing avoids the
# "must supply data" error from `vault kv put k=v` when values start
# with '-' or contain shell-special characters.
#
# Usage:
#   bash /home_ai/.claude/scripts/store-google-identity.sh
#
# Reads VAULT_TOKEN from env (export it first if not already set).

set -euo pipefail

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  echo "✗ VAULT_TOKEN not set. Run:  export VAULT_TOKEN='<your-token>'  first."
  exit 1
fi

# ─── OAuth client ─────────────────────────────────────────────────
echo "── 1/2 OAuth client (used by all 3 consumer-account refresh-token flows) ──"
DEFAULT_CID='371924275288-b26oe2nfnbm9qeoquhva86em8n06so1m.apps.googleusercontent.com'
read -p "client_id [Enter to accept default]: " CID
CID="${CID:-$DEFAULT_CID}"
read -rsp "client_secret (silent): " CSE
printf '\n'
if [[ -z "$CSE" ]]; then
  echo "✗ client_secret empty — aborting"
  exit 1
fi

docker exec -e VAULT_TOKEN -e P_CID="$CID" -e P_CSE="$CSE" homeai-vault sh -c '
  vault kv put secret/google/oauth-client client_id="$P_CID" client_secret="$P_CSE" >/dev/null
'
echo "✓ stored at secret/google/oauth-client"

# ─── Service account JSON (DWD) ──────────────────────────────────
echo
echo "── 2/2 Service account JSON (Workspace domain-wide delegation) ──"
read -p "Path to downloaded JSON key (tab-completes, e.g. ~/Downloads/home-ai-12345-abc.json): " SA_PATH
SA_PATH="${SA_PATH/#\~/$HOME}"   # expand leading ~

if [[ ! -f "$SA_PATH" ]]; then
  echo "✗ file not found: $SA_PATH"
  exit 1
fi

# Basic shape check
if ! grep -q '"type": *"service_account"' "$SA_PATH"; then
  echo "✗ file doesn't look like a Google service account JSON (missing \"type\":\"service_account\")"
  exit 1
fi

SA_BLOB=$(cat "$SA_PATH")

docker exec -e VAULT_TOKEN -e P_SA="$SA_BLOB" homeai-vault sh -c '
  vault kv put secret/google/sa-malthouse json_key="$P_SA" >/dev/null
'
echo "✓ stored at secret/google/sa-malthouse"

# ─── Verify ─────────────────────────────────────────────────────
echo
echo "── Verifying both writes (should print 2, then 1) ──"
docker exec -e VAULT_TOKEN homeai-vault \
  vault kv get -format=json secret/google/oauth-client | grep -cE '"client_id"|"client_secret"'
docker exec -e VAULT_TOKEN homeai-vault \
  vault kv get -format=json secret/google/sa-malthouse | grep -c '"json_key"'

unset CID CSE SA_BLOB SA_PATH
echo
echo "✓ Stage A Vault writes complete."
