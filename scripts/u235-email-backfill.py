#!/usr/bin/env python3
"""U235 — historical Gmail backfill (metadata) for work + personal accounts.

Runs INSIDE homeai-bot-responder (has asyncpg + PG_DSN + network to
homeai-google-fetch). Imports message METADATA (from / subject / received_at /
has_attachment) for the last ~5 years into the `emails` table, idempotently.

Design:
  * Accounts: info/admin = work (entity 1); jo/pounana = personal (entity 3).
  * Iterate week by week from START_DATE → today. /messages caps at 500 with no
    pageToken, so if a week returns >=500 (cap hit) OR has per-message errors,
    re-fetch that week as 7 daily calls (smaller bursts, no cap).
  * INSERT ... ON CONFLICT (gmail_message_id) DO NOTHING — fully re-runnable.
  * processed=true, classification='backfill' so downstream pipelines DON'T
    re-process 5-year-old mail. Body is NOT fetched here (metadata only) — a
    separate phase can backfill bodies on demand.
  * Paced (sleep between calls). Per-account/per-year progress to stdout.

Env overrides: BACKFILL_START (YYYY-MM-DD), BACKFILL_ACCOUNTS (csv).
"""
import os, sys, json, time, asyncio, urllib.request, urllib.parse
from datetime import date, datetime, timedelta, timezone
from email.utils import parseaddr
import asyncpg

GF = "http://homeai-google-fetch:8011"
PG_DSN = os.environ["PG_DSN"]
# account -> (realm, entity_id)
ALL_ACCOUNTS = {
    "info":    ("work", 1),
    "admin":   ("work", 1),
    "jo":      ("personal", 3),
    "pounana": ("personal", 3),
}
START = date.fromisoformat(os.environ.get("BACKFILL_START", "")) if os.environ.get("BACKFILL_START") \
    else (date.today() - timedelta(days=365 * 5 + 7))
ONLY = os.environ.get("BACKFILL_ACCOUNTS")
ACCOUNTS = {k: v for k, v in ALL_ACCOUNTS.items() if (not ONLY or k in ONLY.split(","))}

SLEEP = float(os.environ.get("BACKFILL_SLEEP", "0.4"))


def _gmail_date(d: date) -> str:
    return d.strftime("%Y/%m/%d")


def list_messages(acct: str, after: date, before: date, n: int = 500, tries: int = 3):
    q = urllib.parse.quote(f"after:{_gmail_date(after)} before:{_gmail_date(before)}")
    url = f"{GF}/messages?account={acct}&q={q}&max_results={n}"
    last = None
    for _ in range(tries):
        try:
            r = urllib.request.urlopen(url, timeout=180)
            return json.loads(r.read())
        except Exception as e:
            last = e
            time.sleep(2)
    sys.stderr.write(f"list FAIL {acct} {after}..{before}: {str(last)[:120]}\n")
    return {"messages": [], "count": 0, "_failed": True}


def _received_at(m):
    idt = m.get("internal_date")
    if idt:
        try:
            return datetime.fromtimestamp(int(idt) / 1000.0, tz=timezone.utc)
        except Exception:
            pass
    return None


def collect_week(acct: str, wk_start: date, wk_end: date):
    """Return list of message dicts for the window, splitting to daily on cap/error."""
    res = list_messages(acct, wk_start, wk_end)
    msgs = res.get("messages", [])
    cap_hit = len(msgs) >= 500
    has_err = any(m.get("error") for m in msgs)
    if not cap_hit and not has_err:
        return [m for m in msgs if not m.get("error")]
    # split to daily
    out, d = [], wk_start
    while d < wk_end:
        time.sleep(SLEEP)
        day = list_messages(acct, d, d + timedelta(days=1))
        out.extend([m for m in day.get("messages", []) if not m.get("error")])
        d += timedelta(days=1)
    return out


async def main():
    conn = await asyncpg.connect(PG_DSN)
    today = date.today()
    grand = 0
    print(f"U235 email backfill — accounts={list(ACCOUNTS)} from {START} to {today}", flush=True)
    for acct, (realm, ent) in ACCOUNTS.items():
        acct_total, year_total, cur_year = 0, 0, START.year
        wk = START
        while wk < today:
            wk_end = min(wk + timedelta(days=7), today + timedelta(days=1))
            msgs = collect_week(acct, wk, wk_end)
            if msgs:
                async with conn.transaction():
                    await conn.execute("SELECT set_config('app.current_entity',$1,true)", str(ent))
                    await conn.execute("SELECT set_config('app.current_realm',$1,true)", realm)
                    for m in msgs:
                        name, addr = parseaddr(m.get("from") or "")
                        ins = await conn.fetchval("""
                            INSERT INTO emails (gmail_message_id, account, realm, entity_id,
                                from_address, from_name, subject, received_at, has_attachment,
                                processed, classification)
                            VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,true,'backfill')
                            ON CONFLICT (gmail_message_id) DO NOTHING
                            RETURNING 1
                        """, m["id"], acct, realm, ent, addr or None, name or None,
                             m.get("subject"), _received_at(m), bool(m.get("has_attachment")))
                        if ins:
                            acct_total += 1; year_total += 1; grand += 1
            if wk.year != cur_year:
                print(f"  [{acct}] {cur_year}: +{year_total} new", flush=True)
                cur_year, year_total = wk.year, 0
            wk = wk_end
            time.sleep(SLEEP)
        print(f"  [{acct}] {cur_year}: +{year_total} new", flush=True)
        print(f"[{acct}] DONE — {acct_total} new rows", flush=True)
    await conn.close()
    print(f"U235 backfill complete — {grand} new email rows total", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
