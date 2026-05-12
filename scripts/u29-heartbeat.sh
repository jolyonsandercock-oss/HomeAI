#!/bin/bash
# /home_ai/scripts/u29-heartbeat.sh
#
# 15-min heartbeat: short status pulse to Telegram. Designed to be
# scannable — one line, mostly silent. Cron: */15 * * * *.

set -uo pipefail
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" homeai-playwright python << 'PYEOF'
import os, asyncio, json, urllib.request, urllib.parse
from datetime import datetime
import asyncpg

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN = os.environ["PG_DSN"]


def vault_get(path):
    req = urllib.request.Request(f"http://vault:8200/v1/secret/data/{path}",
                                  headers={"X-Vault-Token": VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(req, timeout=5).read())["data"]["data"]


async def main():
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_entity = 'all'")

    pending_inst = await conn.fetchval(
      "SELECT COUNT(*) FROM bot_instructions WHERE status='pending'")
    firing = await conn.fetchval(
      "SELECT COUNT(*) FROM system_alerts WHERE status='firing' AND acknowledged=false")
    # Most recent successful scrapes — were they today?
    last_to = await conn.fetchval(
      "SELECT MAX(scraped_at) FROM touchoffice_scrapes WHERE success=true")
    last_cb = await conn.fetchval(
      "SELECT MAX(received_at) FROM caterbook_email_reports")
    last_wf = await conn.fetchval(
      "SELECT MAX(started_at) FROM workforce_sync_log WHERE http_status=200")
    dead_letter_open = await conn.fetchval(
      "SELECT COUNT(*) FROM dead_letter WHERE resolved=false")
    await conn.close()

    def stale(ts, hours):
        if ts is None: return "none"
        age_h = (datetime.now(ts.tzinfo) - ts).total_seconds() / 3600
        return f"{int(age_h)}h" if age_h < 99 else "old"

    now = datetime.now().strftime("%H:%M")
    line1 = f"♥ {now} · TO {stale(last_to,1)}ago · CB {stale(last_cb,2)}ago · WF {stale(last_wf,25)}ago"
    line2 = f"   alerts {firing}🔥 · DL {dead_letter_open or 0} · instructions {pending_inst}📨"
    msg = line1 + "\n" + line2

    # Send to Telegram with disable_notification so it doesn't ping the phone
    d = vault_get("telegram")
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{d['bot_token']}/sendMessage",
        data=urllib.parse.urlencode({
            "chat_id": d["chat_id"], "text": msg,
            "disable_notification": "true",
        }).encode())
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        print(f"telegram failed: {e}")

asyncio.run(main())
PYEOF
