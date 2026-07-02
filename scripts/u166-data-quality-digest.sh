#!/bin/bash
# /home_ai/scripts/u166-data-quality-digest.sh
# U166 — daily 06:00 Telegram digest of open data-quality issues.

set -euo pipefail

LOG=/home_ai/logs/u166-data-quality.log
VAULT_TOKEN=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

RESP=$(curl -s -m 30 -H "X-Realm: owner" "http://100.104.82.53:8090/api/finance/slug/data_quality_issues_open")

# Compute total count + format message
MSG=$(echo "$RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = d.get('rows', [])
total = sum(r.get('n', 0) for r in rows)
if total < 10:
    sys.exit(7)  # under threshold — skip Telegram
date_str = '$(date +'%a %d %b')'
lines = [f'📋 Data quality digest — {date_str}', '']
for sev in ('high','medium','low'):
    sev_rows = [r for r in rows if r.get('severity') == sev]
    if not sev_rows: continue
    icon = {'high':'🔴','medium':'🟡','low':'🔵'}[sev]
    for r in sev_rows:
        n = r.get('n', 0)
        if n == 0: continue
        lines.append(f\"{icon} {r['kind']:38s} {n:>4d}  {r['detail']}\")
lines.append('')
lines.append(f'Total: {total} open issues')
lines.append('Investigate: /api/finance/slug/data_quality_issues_open')
print('\\n'.join(lines))
") || {
  echo "$(date -Iseconds)  under-threshold  (no alert)" >> "$LOG"
  exit 0
}

docker exec homeai-bot-responder python -c "
import os, urllib.request, urllib.parse, json
VAULT_TOKEN = os.environ['VAULT_TOKEN']
req = urllib.request.Request('http://vault:8200/v1/secret/data/telegram',
    headers={'X-Vault-Token': VAULT_TOKEN})
d = json.loads(urllib.request.urlopen(req, timeout=5).read())['data']['data']
text = '''$MSG'''
req = urllib.request.Request(f\"https://api.telegram.org/bot{d['bot_token']}/sendMessage\",
    data=urllib.parse.urlencode({'chat_id': d['chat_id'], 'text': text}).encode())
r = urllib.request.urlopen(req, timeout=10)
print('digest sent:', json.loads(r.read()).get('ok'))
"

echo "$(date -Iseconds)  sent digest" >> "$LOG"
