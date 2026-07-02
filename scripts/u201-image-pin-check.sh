#!/bin/bash
# /home_ai/scripts/u201-image-pin-check.sh
# U201 — check docker-compose.yml for unpinned :latest tags.
# Cron: monthly.

set -euo pipefail
LOG=/home_ai/logs/u201-pin-check.log

UNPINNED=$(grep -nE "image: .+:latest" /home_ai/docker-compose.yml || true)

if [ -z "$UNPINNED" ]; then
  echo "$(date -Iseconds)  ok — all images pinned" >> "$LOG"
  exit 0
fi

COUNT=$(echo "$UNPINNED" | wc -l)
echo "$(date -Iseconds)  WARN $COUNT unpinned :latest tags" >> "$LOG"
echo "$UNPINNED" >> "$LOG"

# Telegram on monthly run
docker exec homeai-bot-responder python -c "
import os, urllib.request, urllib.parse, json
VAULT_TOKEN = os.environ['VAULT_TOKEN']
req = urllib.request.Request('http://vault:8200/v1/secret/data/telegram', headers={'X-Vault-Token': VAULT_TOKEN})
d = json.loads(urllib.request.urlopen(req, timeout=5).read())['data']['data']
text = '''🔒 U201 image-pin check: $COUNT unpinned :latest tags in docker-compose.yml

$UNPINNED

Consider pinning per STRETCH §3.1 hygiene.'''
req = urllib.request.Request(f\"https://api.telegram.org/bot{d['bot_token']}/sendMessage\",
    data=urllib.parse.urlencode({'chat_id': d['chat_id'], 'text': text}).encode())
urllib.request.urlopen(req, timeout=10)
"
