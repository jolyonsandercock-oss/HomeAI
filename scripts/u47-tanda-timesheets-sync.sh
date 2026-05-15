#!/bin/bash
# /home_ai/scripts/u47-tanda-timesheets-sync.sh
#
# Tanda /api/v2/timesheets/on/<date> → workforce_timesheets UPSERT.
# Cron: daily 02:20 (5 min after u29-workforce-sync.sh shifts pass).
#
# Usage:
#   ./scripts/u47-tanda-timesheets-sync.sh        # last 30d, weekly samples
#   ./scripts/u47-tanda-timesheets-sync.sh 90     # last N days
#
# Daily mode pulls /on/<today> only. Backfill (N>1) samples every 7 days
# back to today-N — since Tanda pay periods are 4 weeks each timesheet
# will be re-seen multiple times; UPSERT on external_id absorbs the dup.
#
# Hours_total: sum of nested shifts (finish-start)/3600 - break_length/60.
# Cost_total: left NULL — needs pay-rate join, handled separately in
# v_daily_unit_economics. raw_payload retains the full Tanda response.

set -uo pipefail
DAYS="${1:-7}"
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e DAYS="$DAYS" -e VAULT_TOKEN="$VAULT_TOKEN" homeai-playwright python << 'PYEOF'
import os, asyncio, json, time, urllib.request, urllib.parse, urllib.error
from datetime import date as _date, timedelta
import asyncpg

DAYS = int(os.environ["DAYS"])
VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN = os.environ["PG_DSN"]


def to_date(v):
    if v is None or v == "": return None
    try: return _date.fromisoformat(str(v)[:10])
    except Exception: return None


def vault_get(path):
    req = urllib.request.Request(
        f"http://vault:8200/v1/secret/data/{path}",
        headers={"X-Vault-Token": VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(req, timeout=5).read())["data"]["data"]


def wf_call(base, tok, path, params=None):
    url = f"{base}{path}"
    if params:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": f"bearer {tok}"})
    t0 = time.monotonic()
    try:
        r = urllib.request.urlopen(req, timeout=30)
        return r.status, json.loads(r.read()), int((time.monotonic()-t0)*1000), None
    except urllib.error.HTTPError as e:
        return e.code, None, int((time.monotonic()-t0)*1000), e.read().decode()[:500]
    except Exception as e:
        return 0, None, int((time.monotonic()-t0)*1000), str(e)[:500]


def hours_from_shifts(shifts):
    total = 0.0
    if not isinstance(shifts, list): return 0.0
    for s in shifts:
        st, fn = s.get("start"), s.get("finish")
        brk = s.get("break_length") or 0
        if isinstance(st, int) and isinstance(fn, int) and fn > st:
            total += (fn - st) / 3600.0 - (brk or 0) / 60.0
    return round(total, 3)


async def log_sync(conn, endpoint, params, status, seen, ins, upd, err, runtime):
    await conn.execute("SET LOCAL app.current_entity = '1'")
    await conn.execute("""
      INSERT INTO workforce_sync_log
        (endpoint, query_params, records_seen, records_inserted, records_updated,
         http_status, error_message, runtime_ms)
      VALUES ($1,$2::jsonb,$3,$4,$5,$6,$7,$8)
    """, endpoint, json.dumps(params or {}), seen, ins, upd, status, err, runtime)


async def upsert_timesheets(conn, items):
    ins = upd = 0
    async with conn.transaction():
        await conn.execute("SET LOCAL app.current_entity = '1'")
        for t in items:
            hrs = hours_from_shifts(t.get("shifts"))
            n = await conn.fetchval("""
              INSERT INTO workforce_timesheets
                (external_id, user_external_id, period_start, period_end,
                 hours_total, cost_total, status, raw_payload, last_synced_at)
              VALUES ($1,$2,$3,$4,$5,NULL,$6,$7::jsonb,now())
              ON CONFLICT (external_id) DO UPDATE SET
                user_external_id=EXCLUDED.user_external_id,
                period_start=EXCLUDED.period_start, period_end=EXCLUDED.period_end,
                hours_total=EXCLUDED.hours_total, status=EXCLUDED.status,
                raw_payload=EXCLUDED.raw_payload, last_synced_at=now()
              RETURNING (xmax = 0)
            """,
              t.get("id"), t.get("user_id"),
              to_date(t.get("start")), to_date(t.get("finish")),
              hrs, t.get("status"), json.dumps(t))
            if n: ins += 1
            else: upd += 1
    return ins, upd


async def main():
    try:
        creds = vault_get("workforce")
    except Exception as e:
        print(f"PRE-CHECK FAILED: no workforce creds — run scripts/u29-workforce-creds.sh ({e})")
        return
    base = creds.get("base_url", "https://my.workforce.com")
    tok  = creds.get("access_token")
    if not tok:
        print("PRE-CHECK FAILED: access_token missing")
        return

    today = _date.today()
    from_date = today - timedelta(days=DAYS)
    print(f"── tanda timesheets sync: sampling {from_date} → {today} (every 7d) ──")

    conn = await asyncpg.connect(PG_DSN)

    sample = from_date
    total_seen = total_ins = total_upd = 0
    last_status = None
    while sample <= today:
        status, body, ms, err = wf_call(base, tok, f"/api/v2/timesheets/on/{sample.isoformat()}")
        last_status = status
        seen = ins = upd = 0
        if status == 200 and isinstance(body, list):
            seen = len(body)
            ins, upd = await upsert_timesheets(conn, body)
        await log_sync(conn, f"/api/v2/timesheets/on/{sample.isoformat()}",
                       {"on": sample.isoformat()}, status, seen, ins, upd, err, ms)
        total_seen += seen; total_ins += ins; total_upd += upd
        if err:
            print(f"  on {sample}: HTTP {status} {ms}ms  {err}")
        else:
            print(f"  on {sample}: HTTP {status} {ms}ms  seen={seen} ins={ins} upd={upd}")
        sample += timedelta(days=7)

    print(f"── done: last HTTP {last_status}  seen={total_seen} ins={total_ins} upd={total_upd} ──")
    await conn.close()

asyncio.run(main())
PYEOF
