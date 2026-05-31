#!/usr/bin/env python3
"""U237 — backfill email BODIES for the historical metadata import (U235).

Runs in homeai-bot-responder. For each email with no body yet (and not junk),
fetch the full Gmail message via google-fetch and store the plain-text body.
Work realm first (invoices/bookings/suppliers — the high-value set), then
personal. Idempotent (only fills NULL body_text), resumable, paced.
"""
import os, json, time, base64, urllib.request, urllib.parse, asyncio, html, re
import asyncpg

GF = "http://homeai-google-fetch:8011"
PG = os.environ["PG_DSN"]
SLEEP = float(os.environ.get("BODY_SLEEP", "0.15"))
BATCH = 200


def _b64(data):
    if not data:
        return ""
    return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4)).decode("utf-8", "replace")


_TAG = re.compile(r"<[^>]+>")
def _strip_html(s):
    return html.unescape(_TAG.sub(" ", s))


def extract_body(payload):
    """Walk MIME parts: prefer text/plain, fall back to stripped text/html."""
    plain, htmlb = [], []
    def walk(p):
        mt = p.get("mimeType", "")
        if mt == "text/plain":
            plain.append(_b64(p.get("body", {}).get("data")))
        elif mt == "text/html":
            htmlb.append(_b64(p.get("body", {}).get("data")))
        for sub in p.get("parts", []) or []:
            walk(sub)
    walk(payload or {})
    if any(plain):
        return "\n".join(t for t in plain if t).strip()[:50000]
    if any(htmlb):
        return _strip_html("\n".join(t for t in htmlb if t)).strip()[:50000]
    return None


def get_full(account, mid, tries=3):
    url = f"{GF}/message/{account}/{mid}"
    for i in range(tries):
        try:
            return json.loads(urllib.request.urlopen(url, timeout=60).read())
        except Exception as e:
            if i == tries - 1:
                return {"_err": str(e)[:80]}
            time.sleep(3)


async def main():
    conn = await asyncpg.connect(PG)
    done = err = 0
    print("U237 body backfill starting", flush=True)
    while True:
        rows = await conn.fetch("""
            SELECT id, account, gmail_message_id
            FROM emails
            WHERE body_text IS NULL AND classification IS DISTINCT FROM 'ignored'
            ORDER BY (realm='work') DESC, received_at DESC NULLS LAST
            LIMIT $1
        """, BATCH)
        if not rows:
            break
        for r in rows:
            msg = get_full(r["account"], r["gmail_message_id"])
            if msg.get("_err"):
                # mark with empty body so we don't loop forever on a bad one
                await conn.execute("UPDATE emails SET body_text='' WHERE id=$1", r["id"])
                err += 1
                continue
            body = extract_body(msg.get("payload"))
            async with conn.transaction():
                await conn.execute("SELECT set_config('app.current_entity','all',true)")
                await conn.execute("SELECT set_config('app.current_realm','owner',true)")
                await conn.execute(
                    "UPDATE emails SET body_text=$1 WHERE id=$2",
                    (body if body is not None else ""), r["id"])
            done += 1
            time.sleep(SLEEP)
        print(f"  progress: {done} bodies fetched, {err} errors", flush=True)
    await conn.close()
    print(f"U237 body backfill complete — {done} bodies, {err} errors", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
