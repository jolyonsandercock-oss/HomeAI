#!/bin/bash
# /home_ai/scripts/u198-vault-and-restart-watch.sh
# U198 — Vault unexpected seal + container restart-storm watcher.
# Cron: */30 * * * *

set -uo pipefail
LOG=/home_ai/logs/u198-watch.log
STATE=/home_ai/data/u198-last-alert
mkdir -p "$(dirname "$STATE")"

# ── Vault seal check ──
SEALED=$(docker exec homeai-vault vault status -format=json 2>/dev/null | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('sealed', True))
except: print('unknown')
")

SYSTEM_STATE=$(docker exec homeai-postgres psql -U postgres -d homeai -tAc \
  "SELECT value->>'state' FROM static_context WHERE key='system.state'" 2>/dev/null)

if [ "$SEALED" = "True" ] && [ "$SYSTEM_STATE" = "running" ]; then
  if [ "$(cat "$STATE.vault" 2>/dev/null)" != "sealed" ]; then
    echo "$STATE.vault" > "$STATE.vault"
    echo "sealed" > "$STATE.vault"
    docker exec homeai-bot-responder python -c "
import os, urllib.request, urllib.parse, json
VAULT_TOKEN = os.environ['VAULT_TOKEN']
req = urllib.request.Request('http://vault:8200/v1/secret/data/telegram', headers={'X-Vault-Token': VAULT_TOKEN})
d = json.loads(urllib.request.urlopen(req, timeout=5).read())['data']['data']
text = '🚨 VAULT SEALED — unexpected. System state=running. Run vault unseal manually.'
req = urllib.request.Request(f\"https://api.telegram.org/bot{d['bot_token']}/sendMessage\",
    data=urllib.parse.urlencode({'chat_id': d['chat_id'], 'text': text}).encode())
urllib.request.urlopen(req, timeout=10)
"
    echo "$(date -Iseconds)  ALERT vault sealed unexpectedly" >> "$LOG"
  fi
else
  rm -f "$STATE.vault" 2>/dev/null
fi

# ── Container restart-storm ──
# A container that's restarted >2x in the last hour is flapping.
# Use docker inspect's RestartCount; we snapshot it to detect deltas.
SNAPSHOT_NOW=/home_ai/data/u198-restart-snapshot-now.txt
SNAPSHOT_PRIOR=/home_ai/data/u198-restart-snapshot-prior.txt
docker ps --format '{{.Names}}' | while read -r name; do
  count=$(docker inspect "$name" --format '{{.RestartCount}}' 2>/dev/null)
  printf '%s %s\n' "$name" "$count"
done > "$SNAPSHOT_NOW"

if [ -f "$SNAPSHOT_PRIOR" ]; then
  # Compute diffs
  STORM=$(python3 -c "
import sys
now = {}
prior = {}
for line in open('$SNAPSHOT_NOW'):
    n, c = line.strip().split(' ', 1)
    now[n] = int(c)
for line in open('$SNAPSHOT_PRIOR'):
    n, c = line.strip().split(' ', 1)
    prior[n] = int(c)
flapping = []
for n, c in now.items():
    p = prior.get(n, c)
    if c - p > 2:  # > 2 restarts since last check (30 min)
        flapping.append((n, c - p))
if flapping:
    for n, d in flapping:
        print(f'{n}: +{d} restarts in 30min')
")
  if [ -n "$STORM" ]; then
    if [ "$(cat "$STATE.storm" 2>/dev/null)" != "$STORM" ]; then
      echo "$STORM" > "$STATE.storm"
      docker exec homeai-bot-responder python -c "
import os, urllib.request, urllib.parse, json
VAULT_TOKEN = os.environ['VAULT_TOKEN']
req = urllib.request.Request('http://vault:8200/v1/secret/data/telegram', headers={'X-Vault-Token': VAULT_TOKEN})
d = json.loads(urllib.request.urlopen(req, timeout=5).read())['data']['data']
text = '''⚠️ Container restart-storm:
$STORM'''
req = urllib.request.Request(f\"https://api.telegram.org/bot{d['bot_token']}/sendMessage\",
    data=urllib.parse.urlencode({'chat_id': d['chat_id'], 'text': text}).encode())
urllib.request.urlopen(req, timeout=10)
"
      echo "$(date -Iseconds)  ALERT $STORM" >> "$LOG"
    fi
  else
    rm -f "$STATE.storm" 2>/dev/null
  fi
fi

cp "$SNAPSHOT_NOW" "$SNAPSHOT_PRIOR"
echo "$(date -Iseconds)  ok" >> "$LOG"
