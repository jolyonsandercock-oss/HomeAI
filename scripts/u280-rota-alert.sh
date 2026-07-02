#!/bin/bash
# u280-rota-alert.sh — Telegram nudge when the Tanda rota is missing.
#
# UX audit 2026-06-11: today had ZERO shifts in Tanda (staff page blank, Jo
# filed it as "not populating") — the rota simply wasn't published. A blank
# page should never be the alerting mechanism. Checks TOMORROW so there's time
# to publish; alerts at most once per day (stamp file).
# Cron: 16:07 daily (afternoon = time to fix before tomorrow).
set -euo pipefail
STAMP=/home_ai/logs/.u280-last-alert
TOMORROW=$(date -d tomorrow +%Y-%m-%d)

n=$(docker exec homeai-postgres psql -d homeai -U postgres -tAc \
  "SET app.current_entity='1'; SELECT count(*) FROM workforce_shifts WHERE shift_date='$TOMORROW';" 2>/dev/null | tail -1) || n=""
n=${n:-0}

if [ "$n" -ge 3 ]; then
  echo "$(date -Is) [u280] rota ok for $TOMORROW ($n shifts)"
  exit 0
fi
# already alerted today?
if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$(date +%F)" ]; then
  echo "$(date -Is) [u280] rota thin ($n) but already alerted today"
  exit 0
fi

VT=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
docker exec -i -e VT="$VT" -e N="$n" -e D="$TOMORROW" homeai-bot-responder python3 - <<'PY' && date +%F > "$STAMP"
import os, json, urllib.request
vt=os.environ["VT"]
def vault(p):
    r=urllib.request.urlopen(urllib.request.Request(f"http://vault:8200/v1/secret/data/{p}",headers={"X-Vault-Token":vt}),timeout=5)
    return json.loads(r.read())["data"]["data"]
tg=vault("telegram")
msg=(f"📋 *Rota check*: only {os.environ['N']} shift(s) in Tanda for {os.environ['D']}. "
     "Looks unpublished — the staff page and labour tracking will be blank until it is.")
urllib.request.urlopen(urllib.request.Request(
  f"https://api.telegram.org/bot{tg['bot_token']}/sendMessage",
  data=json.dumps({"chat_id":tg["chat_id"],"text":msg,"parse_mode":"Markdown"}).encode(),
  headers={"Content-Type":"application/json"},method="POST"),timeout=10)
print("alert sent")
PY
echo "$(date -Is) [u280] alerted: $n shifts for $TOMORROW"
