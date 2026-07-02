#!/bin/bash
# /home_ai/scripts/u165-freshness-watcher.sh
# U165 — poll data_source_freshness; Telegram if any source 'stale' (>2x cadence).
# Cron: */15 * * * *

set -euo pipefail

LOG=/home_ai/logs/u165-watcher.log
STATE=/home_ai/data/u165-last-alert.json
mkdir -p "$(dirname "$STATE")"

VAULT_TOKEN=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

# Get current freshness via dashboard API
RESP=$(curl -s -m 30 -H "X-Realm: owner" "http://100.104.82.53:8090/api/finance/slug/data_source_freshness")

STALE=$(echo "$RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
stale = [r for r in d.get('rows',[]) if r.get('status') in ('stale','never')]
import json as j
print(j.dumps(stale))
")

STALE_COUNT=$(echo "$STALE" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

if [ "$STALE_COUNT" = "0" ]; then
  echo "$(date -Iseconds)  ok  0 stale sources" >> "$LOG"
  exit 0
fi

# Compare to last-alerted set to avoid spam
LAST_ALERT=""
[ -f "$STATE" ] && LAST_ALERT=$(cat "$STATE")
NOW_HASH=$(echo "$STALE" | sha1sum | cut -d' ' -f1)
if [ "$LAST_ALERT" = "$NOW_HASH" ]; then
  echo "$(date -Iseconds)  unchanged  $STALE_COUNT stale (already alerted)" >> "$LOG"
  exit 0
fi

# Compose Telegram
MSG=$(echo "$STALE" | python3 -c "
import sys, json
stale = json.load(sys.stdin)
lines = ['⚠️ Data source freshness alert', '']
for s in stale:
    age = s.get('age_h')
    age_str = f'{age:.0f}h' if age is not None else 'never'
    exp = s.get('expected_hours')
    lines.append(f\"  • {s['source']:25s} {s['status']:6s} age={age_str} (cadence={exp}h)\")
lines.append('')
lines.append('Investigate via: /api/finance/slug/data_source_freshness')
print('\\n'.join(lines))
")

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
print('alert sent:', json.loads(r.read()).get('ok'))
"

echo "$NOW_HASH" > "$STATE"
echo "$(date -Iseconds)  alerted  $STALE_COUNT stale sources" >> "$LOG"
