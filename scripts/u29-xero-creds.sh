#!/bin/bash
# /home_ai/scripts/u29-xero-creds.sh
#
# Stash Xero OAuth credentials into Vault for both entities.
# Fields per path: client_id, client_secret, refresh_token, tenant_id
#
# Vault paths:
#   secret/xero/trading  — Atlantic Road Trading Ltd
#   secret/xero/estates  — Atlantic Road Estates Ltd
#
# Prerequisite: register the Xero app at https://developer.xero.com/,
# then use the OAuth Playground (or your own flow) to obtain a refresh
# token for each tenant (Trading + Estates).
#
# Re-runnable; idempotency-check before overwrite.

set -euo pipefail
RED='\033[0;31m'; YEL='\033[0;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

VAULT=homeai-vault

docker inspect "$VAULT" >/dev/null 2>&1 || {
  echo -e "${RED}✗${NC} $VAULT not running"; exit 1; }
sealed=$(docker exec "$VAULT" vault status -format=json 2>/dev/null \
         | python3 -c "import json,sys;print(json.load(sys.stdin).get('sealed'))" 2>/dev/null)
[[ "$sealed" == "False" ]] || { echo -e "${RED}✗${NC} Vault is sealed"; exit 1; }

read -rsp "Vault token (kv-rw on secret/xero/*): " VAULT_TOKEN; printf '\n'
[[ -n "$VAULT_TOKEN" ]] || { echo -e "${RED}✗${NC} no token given"; exit 1; }
trap 'unset VAULT_TOKEN CLIENT_ID CLIENT_SECRET REFRESH TENANT' EXIT INT TERM

stash_one() {
  local ent="$1" label="$2" path="secret/xero/$1"
  echo
  echo -e "${CYAN}── $label ($path) ──${NC}"

  if docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
       vault kv get -field=client_id "$path" >/dev/null 2>&1; then
    echo -e "${YEL}!${NC} $path already exists"
    read -rp "Overwrite? [y/N]: " ok
    [[ "${ok:-N}" =~ ^[Yy] ]] || { echo "  skipped"; return 0; }
  fi

  read -rp  "Xero client_id: "       CLIENT_ID
  read -rsp "Xero client_secret: "   CLIENT_SECRET; printf '\n'
  read -rsp "Xero refresh_token: "   REFRESH;       printf '\n'
  read -rp  "Xero tenant_id (UUID): " TENANT

  [[ -n "$CLIENT_ID$CLIENT_SECRET$REFRESH$TENANT" ]] || { echo -e "${RED}✗${NC} empty input"; return 1; }

  docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
    vault kv put "$path" \
      client_id="$CLIENT_ID" \
      client_secret="$CLIENT_SECRET" \
      refresh_token="$REFRESH" \
      tenant_id="$TENANT" >/dev/null

  # Verify (field names only — never echo the secret values)
  for f in client_id client_secret refresh_token tenant_id; do
    n=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
          vault kv get -field=$f "$path" 2>/dev/null | wc -c)
    [[ "$n" -gt 0 ]] || { echo -e "${RED}✗${NC} field $f failed to round-trip"; return 1; }
  done
  echo -e "${GREEN}✓${NC} $path stored (4 fields verified)"
  unset CLIENT_ID CLIENT_SECRET REFRESH TENANT
}

stash_one trading "Trading Ltd (entity_id=1)"
stash_one estates "Estates Ltd (entity_id=2)"

echo
echo -e "${GREEN}── done ──${NC}"
echo "Next: I'll wire P3 Xero Sync against these tokens (U29 chunk 2)."
