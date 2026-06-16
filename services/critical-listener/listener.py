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
import time
import urllib.parse
import urllib.request
from collections import OrderedDict

import asyncpg

CHANNEL   = "telegram_immediate"
DB_DSN    = os.environ["DATABASE_URL"]
VAULT_TOKEN = os.environ["VAULT_TOKEN"]
VAULT_ADDR  = os.environ.get("VAULT_ADDR", "http://vault:8200")
DEDUP_CAP = 256

# Per-kind throttle (U84): the row_id dedup below only catches the SAME exception
# row being notified twice. A storm of DISTINCT rows of the same KIND (e.g. a
# WatchdogN8nErrors flood) still spams Telegram. Throttle by kind — fire the first
# immediately, suppress repeats within the window, and tell the next allowed
# message how many were dropped. Set NOTIFY_THROTTLE_SECONDS=0 to disable.
NOTIFY_THROTTLE_SECONDS = int(os.environ.get("NOTIFY_THROTTLE_SECONDS", "600"))
_last_sent: "OrderedDict[str, float]" = OrderedDict()
_suppressed: "dict[str, int]" = {}


def notify_throttle(kind: str) -> "tuple[bool, int]":
    """Return (should_send, suppressed_count) for an alert of *kind*.

    suppressed_count is the number of same-kind alerts dropped since the last
    send, reported only on the message we let through after the window elapses."""
    if NOTIFY_THROTTLE_SECONDS <= 0:
        return True, 0
    now = time.monotonic()
    last = _last_sent.get(kind)
    if last is not None and (now - last) < NOTIFY_THROTTLE_SECONDS:
        _suppressed[kind] = _suppressed.get(kind, 0) + 1
        return False, 0
    n = _suppressed.pop(kind, 0)
    _last_sent[kind] = now
    _last_sent.move_to_end(kind)
    if len(_last_sent) > DEDUP_CAP:
        _last_sent.popitem(last=False)
    return True, n


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
                kind = p.get("kind") or "exception"
                send, suppressed = notify_throttle(kind)
                if not send:
                    print(f"[throttle] suppressed exc={row_id} kind={kind} "
                          f"(within {NOTIFY_THROTTLE_SECONDS}s window)", flush=True)
                    continue
                msg = format_message(p)
                if suppressed:
                    msg += (f"\n_(+{suppressed} more '{kind}' suppressed in the "
                            f"last {NOTIFY_THROTTLE_SECONDS // 60}m)_")
                print(f"[fire] exc={row_id} kind={kind}", flush=True)
                tg_send(msg)

        except Exception as e:
            print(f"[loop] reconnecting after error: {e}", file=sys.stderr)
            await asyncio.sleep(5)


if __name__ == "__main__":
    asyncio.run(main())
