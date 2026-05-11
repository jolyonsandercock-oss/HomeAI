#!/bin/bash
# /home_ai/scripts/u29-smtp-creds.sh
#
# Stash SMTP credentials for the daily digest emailer.
# Path: secret/smtp/gmail
# Fields: user, app_password, smtp_host, smtp_port
#
# To get an app password for a Gmail account:
#   1. The account must have 2-Step Verification enabled.
#   2. Visit https://myaccount.google.com/apppasswords → generate password
#      for "Mail" / "Other (Home AI digest)" → copy the 16-char password
#      (no spaces).
#
# Defaults: smtp_host=smtp.gmail.com, smtp_port=587 (STARTTLS).

set -euo pipefail
RED='\033[0;31m'; YEL='\033[0;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

VAULT=homeai-vault
VPATH=secret/smtp/gmail

docker inspect "$VAULT" >/dev/null 2>&1 || {
  echo -e "${RED}✗${NC} $VAULT not running"; exit 1; }
sealed=$(docker exec "$VAULT" vault status -format=json 2>/dev/null \
         | python3 -c "import json,sys;print(json.load(sys.stdin).get('sealed'))" 2>/dev/null)
[[ "$sealed" == "False" ]] || { echo -e "${RED}✗${NC} Vault is sealed"; exit 1; }

read -rsp "Vault token (kv-rw on $VPATH): " VAULT_TOKEN; printf '\n'
[[ -n "$VAULT_TOKEN" ]] || { echo -e "${RED}✗${NC} no token given"; exit 1; }
trap 'unset VAULT_TOKEN SMTP_USER APP_PASS SMTP_HOST SMTP_PORT' EXIT INT TERM

echo -e "${CYAN}── U29: SMTP creds → $VPATH ──${NC}"
if docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
     vault kv get -field=user "$VPATH" >/dev/null 2>&1; then
  existing_user=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
                    vault kv get -field=user "$VPATH" 2>/dev/null || echo "?")
  echo -e "${YEL}!${NC} $VPATH already exists (user='${existing_user}')"
  read -rp "Overwrite? [y/N]: " ok
  [[ "${ok:-N}" =~ ^[Yy] ]] || { echo "aborted"; exit 0; }
fi

read -rp  "SMTP user (full Gmail address, e.g. jolyboxbot@gmail.com): " SMTP_USER
read -rsp "16-character app password (silent): " APP_PASS; printf '\n'
read -rp  "smtp_host [smtp.gmail.com]: "         SMTP_HOST
SMTP_HOST=${SMTP_HOST:-smtp.gmail.com}
read -rp  "smtp_port [587]: "                     SMTP_PORT
SMTP_PORT=${SMTP_PORT:-587}

# Sanity check: app password is 16 chars no spaces
clean_pass=$(echo "$APP_PASS" | tr -d '[:space:]')
if [[ ${#clean_pass} -ne 16 ]]; then
  echo -e "${YEL}!${NC} app password should be exactly 16 chars (yours is ${#clean_pass}). Continuing anyway."
fi

docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
  vault kv put "$VPATH" \
    user="$SMTP_USER" \
    app_password="$clean_pass" \
    smtp_host="$SMTP_HOST" \
    smtp_port="$SMTP_PORT" >/dev/null

got_user=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
              vault kv get -field=user "$VPATH" 2>/dev/null)
got_host=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
              vault kv get -field=smtp_host "$VPATH" 2>/dev/null)
pass_len=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
              vault kv get -field=app_password "$VPATH" 2>/dev/null | wc -c)
[[ "$got_user" == "$SMTP_USER" && "$got_host" == "$SMTP_HOST" && "$pass_len" -ge 16 ]] \
  || { echo -e "${RED}✗${NC} round-trip failed"; exit 1; }

echo -e "${GREEN}✓${NC} stored: user='$got_user', host='$got_host:$SMTP_PORT', password=<${pass_len} chars>"
echo
echo -e "${GREEN}── done ──${NC}"
echo "Next: I'll wire P10 Daily Digest workflow (U29 chunk 8)."
