#!/bin/bash
# /home_ai/scripts/u29-instructions-poll.sh
#
# Poll jolyboxbot@gmail.com for new email from jolyon.sandercock@gmail.com,
# queue each as a bot_instructions row, ACK via Telegram so the user knows
# the instruction landed.
#
# Cron: every 5 minutes. Idempotent — UNIQUE(source, source_id) drops dupes.

set -uo pipefail
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" homeai-playwright python << 'PYEOF'
import os, asyncio, json, urllib.request, urllib.parse, base64
from datetime import datetime
import asyncpg

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN = os.environ["PG_DSN"]

ALLOWED_FROM = "jolyon.sandercock@gmail.com"


def vault_get(path):
    req = urllib.request.Request(f"http://vault:8200/v1/secret/data/{path}",
                                  headers={"X-Vault-Token": VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(req, timeout=5).read())["data"]["data"]


def tg_send(text):
    d = vault_get("telegram")
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{d['bot_token']}/sendMessage",
        data=urllib.parse.urlencode({"chat_id": d["chat_id"], "text": text}).encode())
    try:
        return urllib.request.urlopen(req, timeout=10).status
    except Exception as e:
        return f"err: {e}"


def gmail_search(account, q):
    url = f"http://google-fetch:8011/messages?account={account}&max_results=50&q=" + urllib.parse.quote(q)
    return json.loads(urllib.request.urlopen(url, timeout=30).read())


def gmail_body(account, message_id):
    """Pull plain-text body of a Gmail message via google-fetch."""
    url = f"http://google-fetch:8011/message/{account}/{message_id}"
    msg = json.loads(urllib.request.urlopen(url, timeout=15).read())
    def walk(part):
        if part.get("mimeType") == "text/plain" and part.get("body", {}).get("data"):
            b = part["body"]["data"]; pad = "=" * (-len(b) % 4)
            return base64.urlsafe_b64decode(b + pad).decode("utf-8", errors="replace")
        for sub in part.get("parts", []) or []:
            t = walk(sub)
            if t: return t
        return None
    return walk(msg.get("payload", {})) or ""


async def main():
    # Last 1d window via Gmail (its newer_than:Nm parsing is unreliable);
    # then enforce a strict 15-min server-side cutoff ourselves.
    from datetime import timedelta
    cutoff = datetime.utcnow() - timedelta(minutes=15)
    o = gmail_search("bot", f'newer_than:1d from:{ALLOWED_FROM}')
    msgs = o.get("messages", [])
    if not msgs:
        return  # quiet — no instructions, no spam

    conn = await asyncpg.connect(PG_DSN)
    new = 0
    for m in msgs:
        mid = m.get("id")
        subj = (m.get("subject") or "")[:200]
        from_user = m.get("from") or "?"
        internal_date = int(m.get("internal_date") or 0)
        received = datetime.fromtimestamp(internal_date / 1000) if internal_date else datetime.utcnow()
        if received < cutoff:
            continue  # too old — outside the 15-min window
        body = gmail_body("bot", mid)
        triage = (subj + " · " + body[:120].replace("\n", " ")).strip()[:240]

        async with conn.transaction():
            await conn.execute("SET LOCAL app.current_entity = '3'")
            inserted = await conn.fetchval("""
              INSERT INTO bot_instructions (source, source_id, from_user, received_at,
                                              raw_subject, raw_text, triage_summary)
              VALUES ('email', $1, $2, $3, $4, $5, $6)
              ON CONFLICT (source, source_id) DO NOTHING
              RETURNING id
            """, mid, ALLOWED_FROM, received, subj, body, triage)
        if inserted:
            new += 1
            ack = f"📨 instruction queued (#{inserted}):\n{subj[:80]}\nClaude will pick up on next session."
            tg_send(ack)

    await conn.close()
    if new:
        print(f"queued {new} new instruction(s)")

asyncio.run(main())
PYEOF
