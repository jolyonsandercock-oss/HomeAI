#!/bin/bash
# /home_ai/scripts/u29-instructions-poll.sh
#
# Poll jolyboxbot@gmail.com for new email from ALL senders, queue each as a
# bot_instructions row, classify into lane='query'|'data' (attachments →
# data lane; plain mail → query lane).
#
# - Query lane:  bot-responder picks up. ACK via Telegram only if sender is
#                whitelisted in bot_sender_whitelist. Non-whitelisted: row
#                still queued (status='pending') for the responder to mark
#                'rejected' and silently log to query_rejections.
# - Data lane:   u33-data-lane-router picks up. No Telegram ACK (data-lane
#                router has its own logging).
#
# Cron: every 5 minutes. Idempotent — UNIQUE(source, source_id) drops dupes.

set -euo pipefail
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" homeai-playwright python << 'PYEOF'
import os, asyncio, json, urllib.request, urllib.parse, base64, re
from datetime import datetime, timezone, timedelta
import asyncpg

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN = os.environ["PG_DSN"]

DATA_LANE_MIMES = {
    "application/pdf",
    "text/csv",
    "application/csv",
    "application/vnd.ms-excel",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
}


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


def gmail_message(account, message_id):
    url = f"http://google-fetch:8011/message/{account}/{message_id}"
    return json.loads(urllib.request.urlopen(url, timeout=15).read())


def extract_body(payload):
    def walk(part):
        if part.get("mimeType") == "text/plain" and part.get("body", {}).get("data"):
            b = part["body"]["data"]; pad = "=" * (-len(b) % 4)
            return base64.urlsafe_b64decode(b + pad).decode("utf-8", errors="replace")
        for sub in part.get("parts", []) or []:
            t = walk(sub)
            if t:
                return t
        return None
    return walk(payload or {}) or ""


def has_data_attachment(payload):
    def walk(part):
        if part.get("body", {}).get("attachmentId"):
            mime = (part.get("mimeType") or "").lower()
            if mime in DATA_LANE_MIMES:
                return True
        for sub in part.get("parts", []) or []:
            if walk(sub):
                return True
        return False
    return walk(payload or {})


def normalise_sender(from_user):
    if not from_user:
        return None
    m = re.search(r"<([^>]+@[^>]+)>", from_user)
    if m:
        return m.group(1).strip().lower()
    if "@" in from_user:
        return from_user.strip().lower()
    return None


BOT_OWN_ADDRESSES = {"jolyboxbot@gmail.com"}

async def main():
    cutoff = datetime.now(timezone.utc) - timedelta(minutes=15)
    o = gmail_search("bot", "newer_than:1d -in:chats")
    msgs = o.get("messages", [])
    if not msgs:
        # heartbeat even on empty inbox — silent exit here made cron-health
        # flag this job dead for 7h on 2026-07-03 (log-mtime proxy)
        print("queued: query=0 data=0 skipped_self=0 (empty inbox)")
        return

    conn = await asyncpg.connect(PG_DSN)

    async with conn.transaction():
        await conn.execute("SET LOCAL app.current_entity = '3'")
        wl_rows = await conn.fetch("SELECT email FROM bot_sender_whitelist WHERE active")
        whitelist = {r["email"].lower() for r in wl_rows}

    queued_query = 0
    queued_data  = 0
    skipped_self = 0
    for m in msgs:
        mid = m.get("id")
        subj = (m.get("subject") or "")[:200]
        from_user = m.get("from") or "?"
        sender = normalise_sender(from_user)
        # Self-loop guard: never queue a message whose From is the bot itself.
        # Gmail threads expose the bot's own replies as new messages; without
        # this guard they cycle as fake "instructions" and pile up rejections.
        if sender and sender.lower() in BOT_OWN_ADDRESSES:
            skipped_self += 1
            continue
        internal_date = int(m.get("internal_date") or 0)
        received = (datetime.fromtimestamp(internal_date / 1000, tz=timezone.utc)
                    if internal_date else datetime.now(timezone.utc))
        if received < cutoff:
            continue

        msg = gmail_message("bot", mid)
        payload = msg.get("payload", {})
        body = extract_body(payload)
        lane = "data" if has_data_attachment(payload) else "query"
        triage = (subj + " · " + body[:120].replace("\n", " ")).strip()[:240]

        async with conn.transaction():
            await conn.execute("SET LOCAL app.current_entity = '3'")
            inserted = await conn.fetchval("""
              INSERT INTO bot_instructions (source, source_id, from_user, received_at,
                                              raw_subject, raw_text, triage_summary,
                                              lane, sender_email)
              VALUES ('email', $1, $2, $3, $4, $5, $6, $7, $8)
              ON CONFLICT (source, source_id) DO NOTHING
              RETURNING id
            """, mid, from_user, received, subj, body, triage, lane, sender)

        if not inserted:
            continue
        if lane == "data":
            queued_data += 1
            continue
        queued_query += 1
        if sender and sender in whitelist:
            ack = f"📨 instruction queued (#{inserted}):\n{subj[:80]}\nResponder will reply within ~5 min."
            tg_send(ack)

    await conn.close()
    # unconditional heartbeat — a conditional print here left the cron log
    # untouched on quiet cycles and cron-health falsely flagged the job dead
    print(f"queued: query={queued_query} data={queued_data} skipped_self={skipped_self}")

asyncio.run(main())
PYEOF
