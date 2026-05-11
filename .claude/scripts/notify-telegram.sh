#!/bin/bash
# Sends a Telegram message via the bot creds at secret/telegram.
# Reads creds via the running homeai-n8n container's VAULT_TOKEN
# (which has read access to secret/telegram per n8n-policy.hcl).
#
# Usage: bash notify-telegram.sh "message text"
# HTML mode supported (use <b>, <i>, etc.).

set -uo pipefail

MSG="${1:-(empty message)}"

# Pull bot creds — try homeai-google-fetch first (its policy is exactly what we
# need); fall back to homeai-n8n (its policy also reads secret/telegram for the
# daily-digest workflow). Either container's VAULT_TOKEN is fine.
RESP=""
for SRC in homeai-google-fetch homeai-n8n; do
  if ! docker ps --filter "name=$SRC" --format '{{.Names}}' | grep -q "$SRC"; then
    continue
  fi
  RESP=$(docker exec "$SRC" sh -c '
    if command -v python3 >/dev/null 2>&1; then
      python3 -c "
import os, urllib.request
req = urllib.request.Request(\"http://vault:8200/v1/secret/data/telegram\",
                             headers={\"X-Vault-Token\": os.environ[\"VAULT_TOKEN\"]})
print(urllib.request.urlopen(req, timeout=5).read().decode())
"
    else
      wget -qO- --header="X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/secret/data/telegram"
    fi
  ' 2>&1)
  if printf '%s' "$RESP" | grep -q '"bot_token"'; then break; fi
done

# Final fallback: post to the n8n notify-bridge-v1 webhook. This works whenever
# n8n + Vault are both running (regardless of google-fetch state) because n8n
# uses its own credential store.
if ! printf '%s' "$RESP" | grep -q '"bot_token"'; then
  if curl -sS --max-time 15 -X POST \
       -H 'Content-Type: application/json' \
       --data-raw "{\"text\":$(printf '%s' "$MSG" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}" \
       'http://100.104.82.53:5678/webhook/notify-bridge-v1/webhook/notify-bridge' \
       -o /dev/null -w 'tg-via-bridge HTTP=%{http_code}\n' 2>&1 | grep -q '200'; then
    exit 0
  fi
fi

BOT_TOKEN=$(printf '%s' "$RESP" | python3 -c \
  "import json, sys; print(json.load(sys.stdin)['data']['data']['bot_token'])" 2>/dev/null)
CHAT_ID=$(printf '%s' "$RESP" | python3 -c \
  "import json, sys; print(json.load(sys.stdin)['data']['data']['chat_id'])" 2>/dev/null)

if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
  echo "✗ failed to read telegram creds: $RESP" >&2
  exit 1
fi

# Send via curl. Telegram accepts form-urlencoded.
curl -sS --max-time 15 -X POST \
  "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${CHAT_ID}" \
  --data-urlencode "text=${MSG}" \
  --data-urlencode "parse_mode=HTML" \
  --data-urlencode "disable_web_page_preview=true" \
  -o /dev/null -w 'tg HTTP=%{http_code}\n' 2>&1
