#!/bin/bash
# /home_ai/scripts/u47d-cafe-vendor-prompt.sh
#
# One-shot: send top-25 vendors by spend to Telegram, ask Jo which are
# cafe-only. Reply is consumed by u47d-cafe-vendor-apply.sh.
#
# Format expected back from Jo:
#   cafe: 1,4,7,12
# Anything else is ignored — the original 'shared' default holds.

set -uo pipefail
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" homeai-playwright python << 'PYEOF'
import os, asyncio, json, urllib.request, urllib.parse, urllib.error
import asyncpg

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN = os.environ["PG_DSN"]


def vault_get(path, key=None):
    req = urllib.request.Request(
        f"http://vault:8200/v1/secret/data/{path}",
        headers={"X-Vault-Token": VAULT_TOKEN})
    d = json.loads(urllib.request.urlopen(req, timeout=5).read())["data"]["data"]
    return d[key] if key else d


def tg_send(token, chat_id, text):
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendMessage",
        data=urllib.parse.urlencode({
            "chat_id": chat_id, "text": text, "parse_mode": "Markdown",
        }).encode())
    r = urllib.request.urlopen(req, timeout=15)
    return json.loads(r.read())


async def main():
    tg_token = vault_get("telegram", "bot_token")
    tg_chat  = vault_get("telegram", "chat_id")

    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET LOCAL app.current_entity = 'all'")
    rows = await conn.fetch("""
      SELECT vi.vendor_domain,
             COALESCE(MAX(NULLIF(vi.vendor_name,'')),'?') AS sample_name,
             COUNT(*)::int AS invoice_count,
             COALESCE(SUM(vi.gross_amount),0)::numeric(10,2) AS gross_total
      FROM vendor_invoice_inbox vi
      WHERE vi.vendor_domain IS NOT NULL
        AND vi.vendor_domain <> 'gmail.com'
      GROUP BY vi.vendor_domain
      ORDER BY gross_total DESC NULLS LAST
      LIMIT 25
    """)

    candidates = []
    for i, r in enumerate(rows, start=1):
        candidates.append({
            "idx": i,
            "domain": r["vendor_domain"],
            "name": r["sample_name"][:60],
            "count": r["invoice_count"],
            "gross": float(r["gross_total"]),
        })

    lines = ["*U47d — Cafe vendor classification*",
             "Reply with `cafe: 1,4,7` to tag cafe-only vendors.",
             "Anything not listed stays as 'shared'.",
             ""]
    for c in candidates:
        name = c["name"].split("<")[0].strip().strip('"')[:32]
        lines.append(f"`{c['idx']:>2}` £{c['gross']:>8,.0f}  {c['domain'][:30]}  _{name}_")

    body = "\n".join(lines)
    if len(body) > 3800:
        body = body[:3800] + "\n…(truncated)"

    sent = tg_send(tg_token, tg_chat, body)
    msg_id = sent.get("result", {}).get("message_id")
    chat_id = sent.get("result", {}).get("chat", {}).get("id")
    print(f"Telegram sent: msg_id={msg_id} chat_id={chat_id}")

    await conn.execute("SET LOCAL app.current_entity = '1'")
    pid = await conn.fetchval("""
      INSERT INTO cafe_vendor_prompt_state
        (telegram_message_id, telegram_chat_id, candidates)
      VALUES ($1, $2, $3::jsonb)
      RETURNING id
    """, msg_id, chat_id, json.dumps(candidates))
    print(f"Staged prompt id={pid} with {len(candidates)} candidates.")
    await conn.close()

asyncio.run(main())
PYEOF
