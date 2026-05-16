#!/bin/bash
# u121-obligations-reminder.sh — daily Telegram nudge for obligations due ≤ 3 days
#
# Reads v_obligations_due_3d. For each row not already in obligation_reminders,
# Telegrams Jo and records the reminder so it doesn't fire twice.
#
# Cron: 8am daily.

set -uo pipefail
VAULT_TOKEN=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" homeai-bot-responder python3 -u <<'PYEOF'
import os, json, urllib.request, asyncio, asyncpg
from datetime import date

TOK = os.environ["VAULT_TOKEN"]

def vault(p):
    r = urllib.request.urlopen(urllib.request.Request(
        f"http://vault:8200/v1/secret/data/{p}",
        headers={"X-Vault-Token": TOK}), timeout=5)
    return json.loads(r.read())["data"]["data"]


def tg_send(text):
    tg = vault("telegram")
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{tg['bot_token']}/sendMessage",
        data=json.dumps({
            "chat_id": tg["chat_id"], "text": text,
            "parse_mode": "Markdown", "disable_web_page_preview": True,
        }).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    return urllib.request.urlopen(req, timeout=10).read()


async def main():
    pg = vault("postgres")["password"]
    conn = await asyncpg.connect(f"postgresql://postgres:{pg}@homeai-postgres:5432/homeai")
    await conn.execute("SELECT home_ai.set_realm('owner')")

    rows = await conn.fetch("""
        SELECT o.source, o.source_ref, o.label, o.due_date::date AS due_date, o.kind, o.notes
          FROM v_obligations_due_3d o
          LEFT JOIN obligation_reminders r
            ON r.source = o.source AND r.source_ref = o.source_ref
           AND r.due_date = o.due_date::date
         WHERE r.id IS NULL
         ORDER BY o.due_date, o.source
    """)
    if not rows:
        print("nothing new to remind")
        return

    today = date.today()
    by_day = {}
    for r in rows:
        delta = (r["due_date"] - today).days
        by_day.setdefault(delta, []).append(r)

    lines = ["📅 *Upcoming obligations*"]
    for delta in sorted(by_day):
        if delta == 0:   header = "*Today*"
        elif delta == 1: header = "*Tomorrow*"
        else:            header = f"*In {delta} days*"
        lines.append(f"\n{header}")
        for r in by_day[delta]:
            lines.append(f"  • {r['label']} — _{r['kind']}_")
    tg_send("\n".join(lines))

    # Record so we don't double-fire
    for r in rows:
        await conn.execute("""
            INSERT INTO obligation_reminders (source, source_ref, due_date)
            VALUES ($1, $2, $3)
            ON CONFLICT (source, source_ref, due_date) DO NOTHING
        """, r["source"], r["source_ref"], r["due_date"])

    print(f"reminded {len(rows)} obligations across {len(by_day)} day-buckets")
    await conn.close()

asyncio.run(main())
PYEOF
