#!/bin/bash
# /home_ai/scripts/u29-workforce-sync.sh
#
# One-shot Workforce.com (Tanda) → Postgres sync.
# Reads access_token from secret/workforce, pulls users / locations /
# departments / shifts / timesheets / wage_comparisons (last 90d by default),
# UPSERTs into workforce_* tables.
#
# Idempotent — UPSERTs on external_id. Logs every API call to workforce_sync_log.
#
# Usage:
#   ./scripts/u29-workforce-sync.sh           # last 90d incremental
#   ./scripts/u29-workforce-sync.sh 365       # last N days
#
# Pre-req: scripts/u29-workforce-creds.sh ran successfully.

set -uo pipefail
DAYS="${1:-90}"
DAYS_FORWARD="${2:-21}"
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e DAYS="$DAYS" -e DAYS_FORWARD="$DAYS_FORWARD" -e VAULT_TOKEN="$VAULT_TOKEN" homeai-playwright python << 'PYEOF'
import os, asyncio, json, time, urllib.request, urllib.parse, urllib.error
from datetime import date as _date, datetime as _dt, timedelta
import asyncpg


def to_date(v):
    if v is None or v == "": return None
    if isinstance(v, _date): return v
    try: return _date.fromisoformat(str(v)[:10])
    except Exception: return None


def to_dt(v):
    if v is None or v == "": return None
    if isinstance(v, _dt): return v
    s = str(v).replace("Z", "+00:00")
    try: return _dt.fromisoformat(s)
    except Exception:
        try: return _dt.fromtimestamp(int(v))
        except Exception: return None

DAYS = int(os.environ["DAYS"])
DAYS_FORWARD = int(os.environ.get("DAYS_FORWARD", "21"))
VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN = os.environ["PG_DSN"]


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


async def log_sync(conn, endpoint, params, status, seen, ins, upd, err, runtime):
    await conn.execute("SET LOCAL app.current_entity = '1'")
    await conn.execute("""
      INSERT INTO workforce_sync_log
        (endpoint, query_params, records_seen, records_inserted, records_updated,
         http_status, error_message, runtime_ms)
      VALUES ($1,$2::jsonb,$3,$4,$5,$6,$7,$8)
    """, endpoint, json.dumps(params or {}), seen, ins, upd, status, err, runtime)


async def upsert_users(conn, items):
    ins = upd = 0
    async with conn.transaction():
        await conn.execute("SET LOCAL app.current_entity = '1'")
        for u in items:
            n = await conn.fetchval("""
              INSERT INTO workforce_users (external_id, email, full_name, preferred_name,
                                            active, hire_date, termination_date,
                                            base_pay_rate, pay_unit, raw_payload, last_synced_at)
              VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10::jsonb,now())
              ON CONFLICT (external_id) DO UPDATE SET
                email=EXCLUDED.email, full_name=EXCLUDED.full_name,
                preferred_name=EXCLUDED.preferred_name, active=EXCLUDED.active,
                hire_date=EXCLUDED.hire_date, termination_date=EXCLUDED.termination_date,
                base_pay_rate=EXCLUDED.base_pay_rate, pay_unit=EXCLUDED.pay_unit,
                raw_payload=EXCLUDED.raw_payload, last_synced_at=now()
              RETURNING (xmax = 0) AS inserted
            """,
              u.get("id"), u.get("email"), u.get("name"), u.get("preferred_name"),
              u.get("active"), to_date(u.get("hire_date")), to_date(u.get("termination_date")),
              u.get("base_pay_rate"), u.get("pay_unit"),
              json.dumps(u))
            if n: ins += 1
            else: upd += 1
    return ins, upd


async def upsert_locations(conn, items):
    ins = upd = 0
    async with conn.transaction():
        await conn.execute("SET LOCAL app.current_entity = '1'")
        for l in items:
            n = await conn.fetchval("""
              INSERT INTO workforce_locations (external_id, name, raw_payload, last_synced_at)
              VALUES ($1,$2,$3::jsonb,now())
              ON CONFLICT (external_id) DO UPDATE SET
                name=EXCLUDED.name, raw_payload=EXCLUDED.raw_payload, last_synced_at=now()
              RETURNING (xmax = 0)
            """, l.get("id"), l.get("name") or l.get("full_name"), json.dumps(l))
            if n: ins += 1
            else: upd += 1
    return ins, upd


async def upsert_shifts(conn, items):
    ins = upd = 0
    async with conn.transaction():
        await conn.execute("SET LOCAL app.current_entity = '1'")
        for s in items:
            start_unix  = s.get("start")
            finish_unix = s.get("finish")
            break_min   = s.get("break_length") or 0
            hours = None
            if isinstance(start_unix, int) and isinstance(finish_unix, int) and finish_unix > start_unix:
                hours = round((finish_unix - start_unix) / 3600 - break_min/60, 3)
            # Workforce base wage cost (show_costs=true). cost = award + allowance.
            cb = s.get("cost_breakdown") or {}
            award_cost     = cb.get("award_cost")
            allowance_cost = cb.get("allowance_cost")
            if award_cost is None and s.get("cost") is not None:
                award_cost = s.get("cost")  # fallback if breakdown absent
            n = await conn.fetchval("""
              INSERT INTO workforce_shifts (external_id, user_external_id, location_external_id,
                                             department_external_id, shift_date, start_time, end_time,
                                             break_minutes, hours_worked, cost_estimate, status,
                                             raw_payload, last_synced_at,
                                             award_cost, allowance_cost, cost_last_synced_at)
              VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12::jsonb,now(),
                      $13::numeric,$14::numeric, CASE WHEN $13::numeric IS NULL THEN NULL ELSE now() END)
              ON CONFLICT (external_id) DO UPDATE SET
                start_time=EXCLUDED.start_time, end_time=EXCLUDED.end_time,
                break_minutes=EXCLUDED.break_minutes,
                hours_worked=EXCLUDED.hours_worked, cost_estimate=EXCLUDED.cost_estimate,
                department_external_id=EXCLUDED.department_external_id,
                status=EXCLUDED.status, raw_payload=EXCLUDED.raw_payload, last_synced_at=now(),
                award_cost=COALESCE(EXCLUDED.award_cost, workforce_shifts.award_cost),
                allowance_cost=COALESCE(EXCLUDED.allowance_cost, workforce_shifts.allowance_cost),
                cost_last_synced_at=CASE WHEN EXCLUDED.award_cost IS NULL
                                         THEN workforce_shifts.cost_last_synced_at ELSE now() END
              RETURNING (xmax = 0)
            """,
              s.get("id"), s.get("user_id"), s.get("location_id"),
              s.get("department_id"), to_date(s.get("date")),
              to_dt(start_unix), to_dt(finish_unix),
              int(break_min) if break_min else None, hours,
              None,  # cost_estimate — unchanged; trigger fills it until Thursday's on-cost rebuild
              s.get("status"), json.dumps(s),
              award_cost, allowance_cost)
            if n: ins += 1
            else: upd += 1
    return ins, upd


async def main():
    try:
        creds = vault_get("workforce")
    except Exception as e:
        print(f"PRE-CHECK FAILED: no workforce creds in Vault yet — run scripts/u29-workforce-creds.sh first ({e})")
        return
    base = creds.get("base_url", "https://my.workforce.com")
    tok  = creds.get("access_token")
    if not tok:
        print("PRE-CHECK FAILED: access_token missing — run scripts/u29-workforce-creds.sh")
        return

    today = _date.today()
    from_date = today - timedelta(days=DAYS)
    to_date_window = today + timedelta(days=DAYS_FORWARD)
    print(f"── workforce.com sync: {from_date} → {to_date_window} "
          f"({DAYS}d back, {DAYS_FORWARD}d forward) ──")

    conn = await asyncpg.connect(PG_DSN)

    # 1. Users (paginate — same 100-row cap as /shifts; >100 staff would
    # silently truncate otherwise. 2026-06-11 review fix.)
    seen = ins = upd = 0
    page = 1
    while page <= 50:
        status, body, ms, err = wf_call(base, tok, "/api/v2/users", {"page": page, "page_size": 100})
        if status != 200 or not isinstance(body, list) or not body:
            break
        seen += len(body)
        i, u = await upsert_users(conn, body)
        ins += i; upd += u
        if len(body) < 100:
            break
        page += 1
    print(f"  users:        HTTP {status} {ms}ms  seen={seen} ins={ins} upd={upd}  {err or ''}")
    await log_sync(conn, "/api/v2/users", {"page_size":100,"pages":page}, status, seen, ins, upd, err, ms)

    # 2. Locations
    status, body, ms, err = wf_call(base, tok, "/api/v2/locations")
    seen = ins = upd = 0
    if status == 200 and isinstance(body, list):
        seen = len(body)
        ins, upd = await upsert_locations(conn, body)
    print(f"  locations:    HTTP {status} {ms}ms  seen={seen} ins={ins} upd={upd}  {err or ''}")
    await log_sync(conn, "/api/v2/locations", {}, status, seen, ins, upd, err, ms)

    # 3. Shifts (date-range query — Tanda caps each call at 31 days, so chunk).
    total_seen = total_ins = total_upd = 0
    last_status = None
    window_start = from_date
    PAGE_SIZE = 100
    MAX_PAGES = 100  # safety cap (10k shifts/window) against an unterminated loop
    while window_start <= to_date_window:
        window_end = min(window_start + timedelta(days=30), to_date_window)
        page = 1
        while page <= MAX_PAGES:
            status, body, ms, err = wf_call(base, tok, "/api/v2/shifts",
                {"from": window_start.isoformat(), "to": window_end.isoformat(),
                 "page": page, "page_size": PAGE_SIZE, "show_costs": "true"})
            last_status = status
            seen = ins = upd = 0
            if status == 200 and isinstance(body, list):
                seen = len(body)
                ins, upd = await upsert_shifts(conn, body)
            await log_sync(conn, "/api/v2/shifts",
                {"from": window_start.isoformat(), "to": window_end.isoformat(), "page": page},
                status, seen, ins, upd, err, ms)
            total_seen += seen; total_ins += ins; total_upd += upd
            if err:
                print(f"  shifts {window_start}..{window_end} p{page}: HTTP {status} {ms}ms  {err}")
            # Tanda caps each page at PAGE_SIZE; a short/empty page means we're done.
            if status != 200 or not isinstance(body, list) or len(body) < PAGE_SIZE:
                break
            page += 1
        window_start = window_end + timedelta(days=1)
    print(f"  shifts:       last HTTP {last_status}  seen={total_seen} ins={total_ins} upd={total_upd}")

    # 4. Wage comparisons
    status, body, ms, err = wf_call(base, tok, "/api/v2/wage_comparisons",
        {"from": from_date.isoformat(), "to": today.isoformat()})
    seen = 0
    if status == 200 and isinstance(body, list):
        seen = len(body)
    print(f"  wage_compare: HTTP {status} {ms}ms  seen={seen}  {err or ''}")
    await log_sync(conn, "/api/v2/wage_comparisons", {"from":from_date.isoformat(),"to":today.isoformat()}, status, seen, 0, 0, err, ms)

    await conn.close()
    print("── done ──")

asyncio.run(main())
PYEOF
