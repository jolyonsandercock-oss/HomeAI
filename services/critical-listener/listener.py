"""critical-listener — LISTEN telegram_immediate; POST to Telegram.

U71 T2 — every INSERT into mart.exceptions with severity='critical' fires
pg_notify('telegram_immediate', json). We LISTEN, dedupe by row id, and
hit the Telegram sendMessage API. No re-architecture of bot-responder
needed; this stays a single tiny purpose-built loop.
"""
from __future__ import annotations
import asyncio
import json
import os
import sys
import urllib.parse
import urllib.request
from collections import OrderedDict

import asyncpg

CHANNEL   = "telegram_immediate"
DB_DSN    = os.environ["DATABASE_URL"]
VAULT_TOKEN = os.environ["VAULT_TOKEN"]
VAULT_ADDR  = os.environ.get("VAULT_ADDR", "http://vault:8200")
DEDUP_CAP = 256


def vault_get(path: str) -> dict:
    req = urllib.request.Request(
        f"{VAULT_ADDR}/v1/secret/data/{path}",
        headers={"X-Vault-Token": VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(req, timeout=5).read())["data"]["data"]


def tg_send(text: str) -> None:
    try:
        d = vault_get("telegram")
        url = f"https://api.telegram.org/bot{d['bot_token']}/sendMessage"
        req = urllib.request.Request(
            url,
            data=urllib.parse.urlencode({
                "chat_id": d["chat_id"],
                "text":    text,
                "parse_mode": "Markdown",
            }).encode())
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        print(f"[telegram] send failed: {e}", file=sys.stderr)


def format_message(p: dict) -> str:
    bits = [
        f"*\U0001F6A8 CRITICAL · {p.get('kind') or 'exception'}*",
        p.get("summary") or "(no summary)",
    ]
    meta = []
    if p.get("site"):   meta.append(f"site=`{p['site']}`")
    if p.get("source"): meta.append(f"src=`{p['source']}`")
    if p.get("id"):     meta.append(f"exc=`{p['id']}`")
    if meta:
        bits.append(" · ".join(meta))
    return "\n".join(bits)


async def main() -> None:
    print(f"[boot] listening on '{CHANNEL}'", flush=True)
    seen: OrderedDict[int, None] = OrderedDict()

    while True:
        try:
            conn = await asyncpg.connect(DB_DSN)
            queue: asyncio.Queue[dict] = asyncio.Queue()

            def _handler(_conn, _pid, _channel, payload):
                try:
                    queue.put_nowait(json.loads(payload))
                except Exception as e:
                    print(f"[nofify] bad payload: {e}", file=sys.stderr)

            await conn.add_listener(CHANNEL, _handler)
            print("[ready] LISTEN registered", flush=True)

            while True:
                p = await queue.get()
                row_id = p.get("id")
                if row_id is not None:
                    if row_id in seen:
                        continue
                    seen[row_id] = None
                    if len(seen) > DEDUP_CAP:
                        seen.popitem(last=False)
                msg = format_message(p)
                print(f"[fire] exc={row_id} kind={p.get('kind')}", flush=True)
                tg_send(msg)

        except Exception as e:
            print(f"[loop] reconnecting after error: {e}", file=sys.stderr)
            await asyncio.sleep(5)


if __name__ == "__main__":
    asyncio.run(main())
