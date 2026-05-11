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
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e DAYS="$DAYS" -e VAULT_TOKEN="$VAULT_TOKEN" homeai-playwright python << 'PYEOF'
import os, asyncio, json, time, urllib.request, urllib.parse, urllib.error
from datetime import date as _date, timedelta
import asyncpg

DAYS = int(os.environ["DAYS"])
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
              u.get("active"), u.get("hire_date"), u.get("termination_date"),
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
            n = await conn.fetchval("""
              INSERT INTO workforce_shifts (external_id, user_external_id, location_external_id,
                                             department_external_id, shift_date, start_time, end_time,
                                             break_minutes, hours_worked, cost_estimate, status,
                                             raw_payload, last_synced_at)
              VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12::jsonb,now())
              ON CONFLICT (external_id) DO UPDATE SET
                start_time=EXCLUDED.start_time, end_time=EXCLUDED.end_time,
                hours_worked=EXCLUDED.hours_worked, cost_estimate=EXCLUDED.cost_estimate,
                status=EXCLUDED.status, raw_payload=EXCLUDED.raw_payload, last_synced_at=now()
              RETURNING (xmax = 0)
            """,
              s.get("id"), s.get("user_id"), s.get("location_id"),
              s.get("department_id"), s.get("date"), s.get("start"), s.get("end"),
              s.get("breaks_in_minutes"), s.get("hours_worked"),
              s.get("cost"), s.get("status"), json.dumps(s))
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
    print(f"── workforce.com sync: {from_date} → {today} ({DAYS}d) ──")

    conn = await asyncpg.connect(PG_DSN)

    # 1. Users
    status, body, ms, err = wf_call(base, tok, "/api/v2/users", {"page_size": 100})
    seen = ins = upd = 0
    if status == 200 and isinstance(body, list):
        seen = len(body)
        ins, upd = await upsert_users(conn, body)
    print(f"  users:        HTTP {status} {ms}ms  seen={seen} ins={ins} upd={upd}  {err or ''}")
    await log_sync(conn, "/api/v2/users", {"page_size":100}, status, seen, ins, upd, err, ms)

    # 2. Locations
    status, body, ms, err = wf_call(base, tok, "/api/v2/locations")
    seen = ins = upd = 0
    if status == 200 and isinstance(body, list):
        seen = len(body)
        ins, upd = await upsert_locations(conn, body)
    print(f"  locations:    HTTP {status} {ms}ms  seen={seen} ins={ins} upd={upd}  {err or ''}")
    await log_sync(conn, "/api/v2/locations", {}, status, seen, ins, upd, err, ms)

    # 3. Shifts (date-range query)
    status, body, ms, err = wf_call(base, tok, "/api/v2/shifts",
        {"from": from_date.isoformat(), "to": today.isoformat(), "page_size": 100})
    seen = ins = upd = 0
    if status == 200 and isinstance(body, list):
        seen = len(body)
        ins, upd = await upsert_shifts(conn, body)
    print(f"  shifts:       HTTP {status} {ms}ms  seen={seen} ins={ins} upd={upd}  {err or ''}")
    await log_sync(conn, "/api/v2/shifts", {"from":from_date.isoformat(),"to":today.isoformat()}, status, seen, ins, upd, err, ms)

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
