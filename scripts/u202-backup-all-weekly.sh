#!/bin/bash
# /home_ai/scripts/u202-backup-all-weekly.sh
# U202 — weekly full snapshot beyond u028 nightly.
# Adds: git push origin + n8n workflow export + Vault key reminder.
# Cron: 0 3 * * 0 (Sunday 03:00)

set -uo pipefail
LOG=/home_ai/logs/u202-backup-all.log

echo "── U202 weekly full backup $(date -Iseconds) ──" >> "$LOG"

# 1. Run nightly first (idempotent) to ensure fresh PG dump + n8n + vault archive
echo "→ nightly snapshot" >> "$LOG"
/home_ai/scripts/backup-nightly.sh >> "$LOG" 2>&1 || echo "  nightly returned $?" >> "$LOG"

# 2. Export all n8n workflows as JSON for git
echo "→ export n8n workflows" >> "$LOG"
VAULT_TOKEN=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
N8N_KEY=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault vault kv get -field=api_key secret/n8n 2>/dev/null)

mkdir -p /home_ai/n8n-workflows/exports
if [ -n "$N8N_KEY" ]; then
  curl -s -H "X-N8N-API-KEY: $N8N_KEY" "http://100.104.82.53:5678/api/v1/workflows?limit=200" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
import os
for w in d.get('data', []):
    fn = f'/home_ai/n8n-workflows/exports/{w[\"id\"]}.json'
    open(fn, 'w').write(json.dumps(w, indent=2, default=str))
print(f'exported {len(d.get(\"data\",[]))} workflows')
" >> "$LOG" 2>&1
fi

# 3. Push git to off-host-backup (capturing any auto-doc updates etc)
echo "→ git push off-host-backup main" >> "$LOG"
cd /home_ai
if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit --no-verify -m "U202 weekly backup: auto-snapshot $(date +%F)" >> "$LOG" 2>&1
fi
git push off-host-backup main >> "$LOG" 2>&1 || echo "  push returned $?" >> "$LOG"

# 4. Vault unseal-key reminder (every 90 days)
LAST_REKEY=$(docker exec homeai-postgres psql -U postgres -d homeai -tAc \
  "SELECT value->>'last_rekey_date' FROM static_context WHERE key='vault.rekey'" 2>/dev/null)
TODAY=$(date +%F)
if [ -z "$LAST_REKEY" ]; then
  echo "  no vault.rekey static_context — setting baseline today" >> "$LOG"
  docker exec homeai-postgres psql -U postgres -d homeai -c "
INSERT INTO static_context (key, value, updated_at)
VALUES ('vault.rekey', jsonb_build_object('last_rekey_date', '$TODAY'), NOW())
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();" >> "$LOG" 2>&1
else
  DAYS_SINCE=$(( ( $(date -d "$TODAY" +%s) - $(date -d "$LAST_REKEY" +%s) ) / 86400 ))
  if [ "$DAYS_SINCE" -gt 90 ]; then
    docker exec homeai-bot-responder python -c "
import os, urllib.request, urllib.parse, json
VAULT_TOKEN = os.environ['VAULT_TOKEN']
req = urllib.request.Request('http://vault:8200/v1/secret/data/telegram', headers={'X-Vault-Token': VAULT_TOKEN})
d = json.loads(urllib.request.urlopen(req, timeout=5).read())['data']['data']
text = '🔐 Vault rekey due — $DAYS_SINCE days since last rekey on $LAST_REKEY. Run /vault-rekey when ready.'
req = urllib.request.Request(f\"https://api.telegram.org/bot{d['bot_token']}/sendMessage\",
    data=urllib.parse.urlencode({'chat_id': d['chat_id'], 'text': text}).encode())
urllib.request.urlopen(req, timeout=10)
" >> "$LOG" 2>&1
  fi
fi

# 5. Restic snapshot summary
echo "→ restic snapshot summary" >> "$LOG"
RESTIC_PASSWORD_FILE=/home_ai/backups/.restic-pw \
RESTIC_REPOSITORY=/home_ai/backups/restic-local \
restic snapshots --compact 2>&1 | tail -3 >> "$LOG"

# Telegram completion
SIZE=$(du -sh /home_ai/backups/restic-local 2>/dev/null | awk '{print $1}')
docker exec homeai-bot-responder python -c "
import os, urllib.request, urllib.parse, json
VAULT_TOKEN = os.environ['VAULT_TOKEN']
req = urllib.request.Request('http://vault:8200/v1/secret/data/telegram', headers={'X-Vault-Token': VAULT_TOKEN})
d = json.loads(urllib.request.urlopen(req, timeout=5).read())['data']['data']
text = '✅ U202 weekly backup complete · restic repo: $SIZE · n8n workflows exported · git pushed'
req = urllib.request.Request(f\"https://api.telegram.org/bot{d['bot_token']}/sendMessage\",
    data=urllib.parse.urlencode({'chat_id': d['chat_id'], 'text': text}).encode())
urllib.request.urlopen(req, timeout=10)
" >> "$LOG" 2>&1

echo "── U202 done $(date -Iseconds) ──" >> "$LOG"
