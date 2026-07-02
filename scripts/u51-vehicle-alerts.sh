#!/bin/bash
# /home_ai/scripts/u51-vehicle-alerts.sh
#
# Daily 09:00 cron. Pulls v_vehicle_alerts (anything due in next 30d),
# Telegrams a digest if any item falls inside 14 days.
# Silent otherwise.

set -euo pipefail
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" homeai-playwright python << 'PYEOF'
import os, asyncio, json, urllib.request, urllib.parse
import asyncpg

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN = os.environ["PG_DSN"]


def vg(p,k):
    return json.loads(urllib.request.urlopen(urllib.request.Request(
        f"http://vault:8200/v1/secret/data/{p}",
        headers={"X-Vault-Token": VAULT_TOKEN}), timeout=5).read())["data"]["data"][k]


async def main():
    c = await asyncpg.connect(PG_DSN)
    await c.execute("SET app.current_entity='all'")
    urgent = await c.fetch("""
      SELECT registration, make_model, kind, due, days_until
        FROM v_vehicle_alerts WHERE days_until <= 14
        ORDER BY due ASC""")
    await c.close()
    if not urgent:
        print("no urgent vehicle alerts")
        return

    lines = ["🚗 Vehicle alerts — due in next 14 days"]
    for r in urgent:
        flag = "⚠️" if r["days_until"] <= 7 else "·"
        lines.append(f"{flag} {r['registration']} {r['make_model']}: {r['kind']} due {r['due']} ({r['days_until']}d)")
    body = "\n".join(lines)

    try:
        tok = vg("telegram","bot_token"); ch = vg("telegram","chat_id")
        urllib.request.urlopen(urllib.request.Request(
            f"https://api.telegram.org/bot{tok}/sendMessage",
            data=urllib.parse.urlencode({"chat_id":ch,"text":body}).encode()),
            timeout=15).read()
        print(f"telegrammed {len(urgent)} alert(s)")
    except Exception as e:
        print(f"telegram failed: {e}")


asyncio.run(main())
PYEOF
