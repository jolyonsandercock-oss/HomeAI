#!/bin/bash
# u216-mortgage-reocr-wrapper.sh
#
# Runs u151b-reocr-vision.py with the right env. Idempotent: ON CONFLICT
# DO NOTHING in mortgage_statement_periods means re-runs only insert new
# periods. Schedules itself nightly to handle API rate-limit + late-arriving
# statements.
#
# Cron: 0 4 * * *  (04:00 daily — Anthropic API is least loaded overnight)

set -euo pipefail
LOG=/home_ai/logs/u216-mortgage-reocr.log
ts() { date -Iseconds; }

VAULT_TOKEN=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-) || VAULT_TOKEN=""
ANTHROPIC_API_KEY=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault vault kv get -field=api_key secret/anthropic 2>/dev/null) || ANTHROPIC_API_KEY=""
PG_PASS=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault vault kv get -field=password secret/postgres 2>/dev/null) || PG_PASS=""
PG_DSN="postgresql://postgres:${PG_PASS}@homeai-postgres:5432/homeai"

if [ -z "$ANTHROPIC_API_KEY" ] || [ -z "$PG_PASS" ]; then
  echo "$(ts) ERR: missing Vault creds" >> "$LOG"
  exit 1
fi

# Quick API liveness check — bail without burning the long script if 529-storm
HTTP_PROBE=$(docker exec -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" homeai-playwright python3 -c "
import urllib.request, json, os, time
req = urllib.request.Request('https://api.anthropic.com/v1/messages',
    headers={'x-api-key': os.environ['ANTHROPIC_API_KEY'], 'anthropic-version': '2023-06-01', 'content-type':'application/json'},
    data=json.dumps({'model':'claude-haiku-4-5-20251001','max_tokens':10,'messages':[{'role':'user','content':'hi'}]}).encode())
st = 'ERR'
for a in range(4):
    try:
        st = str(urllib.request.urlopen(req, timeout=15).status); break
    except Exception as e:
        st = 'ERR %s' % e
        time.sleep(5 * (a + 1))
print(st)
" 2>&1 | tail -1)

if [[ "$HTTP_PROBE" != "200" ]]; then
  echo "$(ts) API not ready ($HTTP_PROBE) — skipping run" >> "$LOG"
  exit 0
fi

docker cp /home_ai/scripts/u151b-reocr-vision.py homeai-playwright:/tmp/u151b-reocr-vision.py
echo "$(ts) starting vision-OCR run" >> "$LOG"
docker exec \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  -e PG_DSN="$PG_DSN" \
  homeai-playwright python3 /tmp/u151b-reocr-vision.py >> "$LOG" 2>&1
echo "$(ts) done" >> "$LOG"
