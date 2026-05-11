#!/bin/bash
# /home_ai/scripts/u29-sheets-creds.sh
#
# Stash Google Sheets OAuth credentials + the cashing-up sheet ID into Vault.
# Path: secret/sheets/cashing_up
# Fields: client_id, client_secret, refresh_token, sheet_id
#
# Prerequisite:
#   1. Create the Cashing Up Google Sheet (cols A-J per SPEC Appendix C).
#      Note its sheet ID (the long string in the URL between /d/ and /edit).
#   2. Use Google OAuth Playground (https://developers.google.com/oauthplayground/)
#      with scope https://www.googleapis.com/auth/spreadsheets to obtain a
#      refresh token tied to the `info` account.
#      (Or use the existing service account if you'd rather grant via DWD.)

set -euo pipefail
RED='\033[0;31m'; YEL='\033[0;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

VAULT=homeai-vault
VPATH=secret/sheets/cashing_up

docker inspect "$VAULT" >/dev/null 2>&1 || {
  echo -e "${RED}✗${NC} $VAULT not running"; exit 1; }
sealed=$(docker exec "$VAULT" vault status -format=json 2>/dev/null \
         | python3 -c "import json,sys;print(json.load(sys.stdin).get('sealed'))" 2>/dev/null)
[[ "$sealed" == "False" ]] || { echo -e "${RED}✗${NC} Vault is sealed"; exit 1; }

read -rsp "Vault token (kv-rw on $VPATH): " VAULT_TOKEN; printf '\n'
[[ -n "$VAULT_TOKEN" ]] || { echo -e "${RED}✗${NC} no token given"; exit 1; }
trap 'unset VAULT_TOKEN CLIENT_ID CLIENT_SECRET REFRESH SHEET_ID' EXIT INT TERM

echo -e "${CYAN}── U29: Cashing-up Sheet creds → $VPATH ──${NC}"
if docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
     vault kv get -field=sheet_id "$VPATH" >/dev/null 2>&1; then
  echo -e "${YEL}!${NC} $VPATH already exists"
  read -rp "Overwrite? [y/N]: " ok
  [[ "${ok:-N}" =~ ^[Yy] ]] || { echo "aborted"; exit 0; }
fi

read -rp  "Cashing-up Sheet ID: "      SHEET_ID
read -rp  "OAuth client_id: "          CLIENT_ID
read -rsp "OAuth client_secret: "      CLIENT_SECRET; printf '\n'
read -rsp "OAuth refresh_token: "      REFRESH;        printf '\n'

[[ -n "$SHEET_ID$CLIENT_ID$CLIENT_SECRET$REFRESH" ]] || { echo -e "${RED}✗${NC} empty input"; exit 1; }

docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
  vault kv put "$VPATH" \
    sheet_id="$SHEET_ID" \
    client_id="$CLIENT_ID" \
    client_secret="$CLIENT_SECRET" \
    refresh_token="$REFRESH" >/dev/null

for f in sheet_id client_id client_secret refresh_token; do
  n=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
        vault kv get -field=$f "$VPATH" 2>/dev/null | wc -c)
  [[ "$n" -gt 0 ]] || { echo -e "${RED}✗${NC} $f failed to round-trip"; exit 1; }
done

echo -e "${GREEN}✓${NC} $VPATH stored (4 fields verified — values not echoed)"
echo
echo -e "${GREEN}── done ──${NC}"
echo "Next: I'll wire P7 Cashing Up workflow (U29 chunk 5)."
