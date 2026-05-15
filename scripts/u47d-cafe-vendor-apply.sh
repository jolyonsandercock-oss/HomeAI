#!/bin/bash
# /home_ai/scripts/u47d-cafe-vendor-apply.sh
#
# Looks at the most recent unapplied cafe_vendor_prompt_state row, then
# scans bot_instructions (sent by Jo, after prompt sent_at) for a
# `cafe: 1,4,7` reply. Applies matching candidates as
# vendor_category_rules rows with site='cafe'. Acks the bot_instructions
# row as 'resolved'. Idempotent: re-runs are a no-op once applied.
#
# Designed to run from cron every 10 minutes after a prompt is sent, OR
# manually any time.

set -uo pipefail
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" homeai-playwright python << 'PYEOF'
import os, asyncio, json, re, urllib.request, urllib.parse
import asyncpg

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN = os.environ["PG_DSN"]
REPLY_RE = re.compile(r"cafe\s*:\s*([0-9,\s]+)", re.IGNORECASE)


def vault_get(path, key=None):
    req = urllib.request.Request(
        f"http://vault:8200/v1/secret/data/{path}",
        headers={"X-Vault-Token": VAULT_TOKEN})
    d = json.loads(urllib.request.urlopen(req, timeout=5).read())["data"]["data"]
    return d[key] if key else d


def tg_send(token, chat_id, text):
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendMessage",
        data=urllib.parse.urlencode({"chat_id": chat_id, "text": text}).encode())
    try: urllib.request.urlopen(req, timeout=15)
    except Exception: pass


async def main():
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET LOCAL app.current_entity = 'all'")

    prompt = await conn.fetchrow("""
      SELECT id, candidates, sent_at, telegram_chat_id
      FROM cafe_vendor_prompt_state
      WHERE applied_at IS NULL
      ORDER BY sent_at DESC LIMIT 1
    """)
    if not prompt:
        print("No unapplied prompt — nothing to do.")
        await conn.close(); return

    reply = await conn.fetchrow("""
      SELECT id, raw_text
      FROM bot_instructions
      WHERE source = 'telegram'
        AND received_at >= $1
        AND raw_text ~* '^\s*cafe\s*:'
        AND status IN ('pending','triaged')
      ORDER BY received_at ASC LIMIT 1
    """, prompt["sent_at"])
    if not reply:
        print(f"Prompt id={prompt['id']} still awaiting cafe reply (sent {prompt['sent_at']}).")
        await conn.close(); return

    m = REPLY_RE.search(reply["raw_text"] or "")
    if not m:
        print("Reply matched filter but couldn't parse ids — skipping.")
        await conn.close(); return
    ids = sorted({int(x) for x in re.split(r"[,\s]+", m.group(1)) if x.strip().isdigit()})
    candidates = prompt["candidates"]
    if isinstance(candidates, str):
        candidates = json.loads(candidates)
    by_idx = {c["idx"]: c for c in candidates}
    targets = [by_idx[i] for i in ids if i in by_idx]
    print(f"Reply parsed: ids={ids} → {len(targets)} matched candidate(s)")

    rule_ids = []
    async with conn.transaction():
        await conn.execute("SET LOCAL app.current_entity = '1'")
        for t in targets:
            pat = re.escape(t["domain"]) + "$"
            rid = await conn.fetchval("""
              INSERT INTO vendor_category_rules
                (domain_pattern, category, vendor_display, priority, site, notes)
              VALUES ($1, 'cafe-supplies', $2, 50, 'cafe', 'U47d cafe prompt reply')
              ON CONFLICT (domain_pattern, site) DO UPDATE SET
                vendor_display=EXCLUDED.vendor_display,
                priority=EXCLUDED.priority,
                notes=EXCLUDED.notes
              RETURNING id
            """, pat, t["name"])
            rule_ids.append(rid)

        await conn.execute("""
          UPDATE cafe_vendor_prompt_state
             SET applied_at=now(), applied_rule_ids=$2
           WHERE id=$1
        """, prompt["id"], rule_ids)

        await conn.execute("""
          UPDATE bot_instructions
             SET status='resolved', resolved_at=now(),
                 resolution=$2
           WHERE id=$1
        """, reply["id"], f"u47d-cafe: applied {len(rule_ids)} cafe rule(s)")

    print(f"Applied {len(rule_ids)} cafe rule(s): {rule_ids}")

    try:
        tg_token = vault_get("telegram", "bot_token")
        tg_chat  = prompt["telegram_chat_id"] or vault_get("telegram", "chat_id")
        names = ", ".join(t["domain"] for t in targets)
        tg_send(tg_token, tg_chat,
                f"✓ U47d: {len(rule_ids)} cafe vendor rule(s) applied — {names[:300]}")
    except Exception as e:
        print(f"(Telegram confirm failed: {e})")

    await conn.close()

asyncio.run(main())
PYEOF
