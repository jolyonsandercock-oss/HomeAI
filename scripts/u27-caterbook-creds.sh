#!/bin/bash
# /home_ai/scripts/u27-caterbook-creds.sh
#
# Interactive: prompt for Caterbook (app.caterbook.net) credentials and
# stash them in Vault at secret/caterbook
# (fields: account_id, username, password).
#
# Used by the U27 Playwright scraper to log in and fetch arrivals/daily summary.
#
# Idempotent: if the path already has values, prompts before overwriting.
# Re-runnable for credential rotation.

set -euo pipefail
RED='\033[0;31m'; YEL='\033[0;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

VAULT=homeai-vault
VPATH=secret/caterbook

docker inspect "$VAULT" >/dev/null 2>&1 || {
  echo -e "${RED}✗${NC} $VAULT not running — run ./start.sh first"; exit 1; }
sealed=$(docker exec "$VAULT" vault status -format=json 2>/dev/null \
         | python3 -c "import json,sys;print(json.load(sys.stdin).get('sealed'))" 2>/dev/null)
if [[ "$sealed" != "False" ]]; then
  echo -e "${RED}✗${NC} Vault is sealed — run ./start.sh to unseal"; exit 1
fi

echo -e "${CYAN}── U27: Caterbook credentials → Vault $VPATH ──${NC}"
echo

read -rsp "Vault token (kv-rw on $VPATH): " VAULT_TOKEN
printf '\n'
[[ -n "$VAULT_TOKEN" ]] || { echo -e "${RED}✗${NC} no token given"; exit 1; }

trap 'unset VAULT_TOKEN ACCOUNT USER PASS PASS2' EXIT INT TERM

# Idempotency check
if docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
     vault kv get -field=username "$VPATH" >/dev/null 2>&1; then
  existing_account=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
                     vault kv get -field=account_id "$VPATH" 2>/dev/null || echo "?")
  existing_user=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
                  vault kv get -field=username "$VPATH" 2>/dev/null)
  echo -e "${YEL}!${NC} $VPATH already exists (account_id='${existing_account}', username='${existing_user}')"
  read -rp "Overwrite? [y/N]: " ok
  [[ "${ok:-N}" =~ ^[Yy] ]] || { echo "aborted"; exit 0; }
fi

read -rp  "Caterbook account ID: " ACCOUNT
[[ -n "$ACCOUNT" ]] || { echo -e "${RED}✗${NC} no account ID given"; exit 1; }
read -rp  "Caterbook username: " USER
[[ -n "$USER" ]] || { echo -e "${RED}✗${NC} no username given"; exit 1; }
read -rsp "Caterbook password (silent): " PASS
printf '\n'
read -rsp "Confirm password: " PASS2
printf '\n'
[[ "$PASS" == "$PASS2" ]] || { echo -e "${RED}✗${NC} passwords don't match"; exit 1; }
[[ -n "$PASS" ]] || { echo -e "${RED}✗${NC} no password given"; exit 1; }

echo -e "${YEL}→${NC} writing $VPATH"
docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
  vault kv put "$VPATH" \
    account_id="$ACCOUNT" \
    username="$USER" \
    password="$PASS" >/dev/null

# Verify (read the field names back — never print the password)
got_account=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
              vault kv get -field=account_id "$VPATH" 2>/dev/null)
got_user=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
           vault kv get -field=username "$VPATH" 2>/dev/null)
got_pass_len=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
               vault kv get -field=password "$VPATH" 2>/dev/null | wc -c)
if [[ "$got_account" == "$ACCOUNT" ]] && [[ "$got_user" == "$USER" ]] && [[ "$got_pass_len" -gt 0 ]]; then
  echo -e "${GREEN}✓${NC} stored: account_id='$got_account', username='$got_user', password=<${got_pass_len} chars>"
else
  echo -e "${RED}✗${NC} verification failed — value didn't round-trip"
  exit 1
fi

echo
echo -e "${GREEN}── done ──${NC}"
echo "Next: u27 touchoffice creds (./scripts/u27-touchoffice-creds.sh) if not yet done, then kick off the scraper build."
