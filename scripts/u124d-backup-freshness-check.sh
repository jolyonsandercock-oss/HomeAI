#!/bin/bash
# u124d-backup-freshness-check.sh — Telegrams if restic snapshot is stale.
# Cron: 30 9 * * 1   (every Monday 09:30)
set -euo pipefail
LATEST=$(restic -p /home_ai/backups/.restic-pw -r /home_ai/backups/restic-local \
                snapshots --json 2>/dev/null | python3 -c "
import json, sys
snaps = json.load(sys.stdin)
if not snaps: print('NONE')
else: print(snaps[-1]['time'][:10])
")
TODAY=$(date +%Y-%m-%d)
DAYS_OLD=$(( ( $(date -d "$TODAY" +%s) - $(date -d "$LATEST" +%s) ) / 86400 ))
if [ "$DAYS_OLD" -gt 2 ]; then
  VAULT_TOKEN=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
  docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-bot-responder python3 -c "
import os, json, urllib.request
TOK=os.environ['VAULT_TOKEN']
tg=json.loads(urllib.request.urlopen(urllib.request.Request('http://vault:8200/v1/secret/data/telegram',headers={'X-Vault-Token':TOK})).read())['data']['data']
msg='ALERT: Home AI restic backup is $DAYS_OLD days stale (last: $LATEST). Check /home_ai/backups/last-backup.log.'
urllib.request.urlopen(urllib.request.Request(f'https://api.telegram.org/bot{tg[\"bot_token\"]}/sendMessage',data=json.dumps({'chat_id':tg['chat_id'],'text':msg}).encode(),headers={'Content-Type':'application/json'},method='POST'),timeout=10).read()
"
  echo "ALERTED: backup stale $DAYS_OLD days"
else
  echo "OK: latest snapshot is $DAYS_OLD days old ($LATEST)"
fi
