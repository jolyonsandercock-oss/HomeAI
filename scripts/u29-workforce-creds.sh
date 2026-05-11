#!/bin/bash
# /home_ai/scripts/u29-workforce-creds.sh
#
# Stash Workforce.com (Tanda) API credentials.
# Path: secret/workforce
# Fields: client_id, client_secret, access_token, refresh_token, base_url
#
# Two flows are supported by the API:
#   - Authorization Code (multi-tenant)
#   - Password Flow         (single account — what we use)
#
# Easiest path:
#   1. Sign into my.workforce.com
#   2. Go to Settings → API → Access Tokens
#      (https://my.workforce.com/api/oauth/access_tokens)
#   3. Generate a long-lived password-flow token. Save the token only —
#      it never expires.
#   4. Optional: also note your client_id/client_secret in case we later
#      switch to OAuth code flow.
#
# Re-runnable. Used by scripts/u29-workforce-sync.sh (sync stub) and the
# U30 nightly sync once that's wired.

set -euo pipefail
RED='\033[0;31m'; YEL='\033[0;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

VAULT=homeai-vault
VPATH=secret/workforce

docker inspect "$VAULT" >/dev/null 2>&1 || { echo -e "${RED}✗${NC} $VAULT not running"; exit 1; }
sealed=$(docker exec "$VAULT" vault status -format=json 2>/dev/null \
         | python3 -c "import json,sys;print(json.load(sys.stdin).get('sealed'))" 2>/dev/null)
[[ "$sealed" == "False" ]] || { echo -e "${RED}✗${NC} Vault is sealed"; exit 1; }

read -rsp "Vault token (kv-rw on $VPATH): " VAULT_TOKEN; printf '\n'
[[ -n "$VAULT_TOKEN" ]] || { echo -e "${RED}✗${NC} no token"; exit 1; }
trap 'unset VAULT_TOKEN CLIENT_ID CLIENT_SECRET ACCESS_TOKEN REFRESH_TOKEN BASE_URL' EXIT INT TERM

echo -e "${CYAN}── U30: Workforce.com creds → $VPATH ──${NC}"
if docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
     vault kv get -field=access_token "$VPATH" >/dev/null 2>&1; then
  echo -e "${YEL}!${NC} $VPATH already exists"
  read -rp "Overwrite? [y/N]: " ok
  [[ "${ok:-N}" =~ ^[Yy] ]] || { echo "aborted"; exit 0; }
fi

echo "(Leave blank to skip OAuth client fields — only access_token is required for password flow.)"
read -rp  "Workforce client_id (or blank): "      CLIENT_ID
if [[ -n "$CLIENT_ID" ]]; then
  read -rsp "Workforce client_secret: "           CLIENT_SECRET; printf '\n'
fi
read -rsp "Workforce access_token (long-lived from /api/oauth/access_tokens): " ACCESS_TOKEN; printf '\n'
read -rsp "Workforce refresh_token (or blank): "  REFRESH_TOKEN; printf '\n'
read -rp  "Base URL [https://my.workforce.com]: " BASE_URL
BASE_URL=${BASE_URL:-https://my.workforce.com}

[[ -n "$ACCESS_TOKEN" ]] || { echo -e "${RED}✗${NC} access_token is required"; exit 1; }

# Build the put command dynamically to skip empty fields.
fields=( access_token="$ACCESS_TOKEN" base_url="$BASE_URL" )
[[ -n "$CLIENT_ID"     ]] && fields+=( client_id="$CLIENT_ID" )
[[ -n "${CLIENT_SECRET:-}" ]] && fields+=( client_secret="$CLIENT_SECRET" )
[[ -n "$REFRESH_TOKEN" ]] && fields+=( refresh_token="$REFRESH_TOKEN" )

docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
  vault kv put "$VPATH" "${fields[@]}" >/dev/null

got_base=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
            vault kv get -field=base_url "$VPATH" 2>/dev/null)
tok_len=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
            vault kv get -field=access_token "$VPATH" 2>/dev/null | wc -c)
[[ "$got_base" == "$BASE_URL" && "$tok_len" -gt 16 ]] \
  || { echo -e "${RED}✗${NC} round-trip failed"; exit 1; }

# Sanity ping: hit /api/v2/users/me to confirm token works
status=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: bearer $ACCESS_TOKEN" \
  "$BASE_URL/api/v2/users/me" || echo 000)
if [[ "$status" == "200" ]]; then
  echo -e "${GREEN}✓${NC} token verified against $BASE_URL/api/v2/users/me  (HTTP 200)"
else
  echo -e "${YEL}!${NC} stored, but /users/me returned HTTP $status — double-check the token scope"
fi

echo
echo -e "${GREEN}── done ──${NC}"
echo "Next: ./scripts/u29-workforce-sync.sh    # one-shot sync to populate the tables"
