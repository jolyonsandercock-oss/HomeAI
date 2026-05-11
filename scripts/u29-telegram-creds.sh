#!/bin/bash
# /home_ai/scripts/u29-telegram-creds.sh
#
# Stash Telegram bot credentials into Vault.
# Path: secret/telegram
# Fields: bot_token, chat_id
#
# How to obtain:
#   bot_token   — message @BotFather on Telegram → /newbot → token
#   chat_id     — message your new bot once, then visit
#                 https://api.telegram.org/bot<TOKEN>/getUpdates and read
#                 result[0].message.chat.id (negative for groups, positive
#                 for direct DMs).
#
# Used by P10 Daily Digest and the bidirectional instruction channel
# (U29 follow-on — see Telegram-instructions design notes).

set -euo pipefail
RED='\033[0;31m'; YEL='\033[0;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

VAULT=homeai-vault
VPATH=secret/telegram

docker inspect "$VAULT" >/dev/null 2>&1 || {
  echo -e "${RED}✗${NC} $VAULT not running"; exit 1; }
sealed=$(docker exec "$VAULT" vault status -format=json 2>/dev/null \
         | python3 -c "import json,sys;print(json.load(sys.stdin).get('sealed'))" 2>/dev/null)
[[ "$sealed" == "False" ]] || { echo -e "${RED}✗${NC} Vault is sealed"; exit 1; }

read -rsp "Vault token (kv-rw on $VPATH): " VAULT_TOKEN; printf '\n'
[[ -n "$VAULT_TOKEN" ]] || { echo -e "${RED}✗${NC} no token given"; exit 1; }
trap 'unset VAULT_TOKEN BOT_TOKEN CHAT_ID' EXIT INT TERM

echo -e "${CYAN}── U29: Telegram creds → $VPATH ──${NC}"
if docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
     vault kv get -field=bot_token "$VPATH" >/dev/null 2>&1; then
  existing_chat=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
                    vault kv get -field=chat_id "$VPATH" 2>/dev/null || echo "?")
  echo -e "${YEL}!${NC} $VPATH already exists (chat_id='${existing_chat}')"
  read -rp "Overwrite? [y/N]: " ok
  [[ "${ok:-N}" =~ ^[Yy] ]] || { echo "aborted"; exit 0; }
fi

read -rsp "Telegram bot_token (from @BotFather, silent): " BOT_TOKEN; printf '\n'
read -rp  "Telegram chat_id (positive for DM, negative for group): " CHAT_ID
[[ -n "$BOT_TOKEN$CHAT_ID" ]] || { echo -e "${RED}✗${NC} empty input"; exit 1; }

docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
  vault kv put "$VPATH" bot_token="$BOT_TOKEN" chat_id="$CHAT_ID" >/dev/null

got_chat=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
            vault kv get -field=chat_id "$VPATH" 2>/dev/null)
tok_len=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
            vault kv get -field=bot_token "$VPATH" 2>/dev/null | wc -c)
[[ "$got_chat" == "$CHAT_ID" && "$tok_len" -gt 10 ]] \
  || { echo -e "${RED}✗${NC} round-trip failed"; exit 1; }

echo -e "${GREEN}✓${NC} stored: chat_id='$got_chat', bot_token=<${tok_len} chars>"
echo
echo -e "${GREEN}── done ──${NC}"
echo "Optional next: send a test ping from the bot:"
echo "  docker exec homeai-playwright python -c \"import urllib.request, urllib.parse; "
echo "    t='$BOT_TOKEN'; "
echo "    urllib.request.urlopen(f'https://api.telegram.org/bot{t}/sendMessage', "
echo "      data=urllib.parse.urlencode({'chat_id':'$CHAT_ID','text':'Home AI test ping'}).encode())\""
