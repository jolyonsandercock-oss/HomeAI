#!/bin/bash
# /home_ai/scripts/u32-workforce-pay-sync.sh
#
# Pulls /api/v2/user_pay_fields from Tanda, picks the CURRENT effective row
# per user (from_date <= today AND (to_date IS NULL OR to_date >= today),
# falling back to the most recent from_date), converts to pence/hour, and
# upserts into staff_meta.
#
# Salaried staff (yearly_salary > 0, hourly_rate = 0) get an implied hourly
# rate of yearly_salary / 52 / 40 — assumes 40h/week as the default.
#
# Idempotent. Cron candidate: */weekly (rates rarely change).

set -uo pipefail
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" homeai-playwright python << 'PYEOF'
import os, asyncio, json, urllib.request, urllib.parse, urllib.error
from datetime import date as _date
import asyncpg

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN = os.environ["PG_DSN"]

def vault_get(path):
    req = urllib.request.Request(f"http://vault:8200/v1/secret/data/{path}",
                                  headers={"X-Vault-Token": VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(req, timeout=5).read())["data"]["data"]


def fetch_all_pay_fields(base, tok):
    """Paginate /user_pay_fields, return [{user_id, hourly_rate, yearly_salary, from_date, to_date}, ...]."""
    rows = []
    page = 1
    while True:
        url = f"{base}/api/v2/user_pay_fields?" + urllib.parse.urlencode({"page": page, "page_size": 100})
        r = urllib.request.urlopen(urllib.request.Request(url,
            headers={"Authorization": f"bearer {tok}"}), timeout=30)
        batch = json.loads(r.read())
        if not isinstance(batch, list) or not batch:
            break
        rows.extend(batch)
        if len(batch) < 100:
            break
        page += 1
        if page > 50:  # safety cap (won't realistically have 5000 rows)
            break
    return rows


def effective_rate_for_user(rows, today):
    """Pick the current pay-field row for a single user.
    Priority: any row where from_date <= today AND (to_date NULL OR >= today);
    of those, the one with the latest from_date. If none current, fall back
    to the row with the highest from_date overall."""
    current = []
    for r in rows:
        try:
            fd = _date.fromisoformat(r.get("from_date", "1970-01-01"))
        except Exception:
            continue
        if fd > today:
            continue
        td_str = r.get("to_date")
        td = None
        if td_str:
            try: td = _date.fromisoformat(td_str)
            except Exception: pass
        if td is None or td >= today:
            current.append((fd, r))
    if current:
        current.sort(key=lambda x: x[0], reverse=True)
        return current[0][1]
    # fallback: latest row
    rows_with_date = []
    for r in rows:
        try:
            fd = _date.fromisoformat(r.get("from_date", "1970-01-01"))
            rows_with_date.append((fd, r))
        except Exception:
            pass
    if not rows_with_date:
        return None
    rows_with_date.sort(key=lambda x: x[0], reverse=True)
    return rows_with_date[0][1]


def to_pence_per_hour(field, default_hours_per_week=40):
    """Return effective rate in pence/hour."""
    hr = float(field.get("hourly_rate") or 0)
    if hr > 0:
        return int(round(hr * 100))
    ys = float(field.get("yearly_salary") or 0)
    if ys > 0:
        weekly = ys / 52.0
        hourly = weekly / default_hours_per_week
        return int(round(hourly * 100))
    return None


async def main():
    creds = vault_get("workforce")
    base, tok = creds["base_url"], creds["access_token"]
    today = _date.today()

    pay = fetch_all_pay_fields(base, tok)
    print(f"fetched {len(pay)} pay_field rows total")
    by_user = {}
    for r in pay:
        uid = r.get("user_id")
        if uid is None: continue
        by_user.setdefault(uid, []).append(r)
    print(f"covering {len(by_user)} distinct users")

    conn = await asyncpg.connect(PG_DSN)
    written = skipped_zero = 0

    async with conn.transaction():
        await conn.execute("SET LOCAL app.current_entity = '1'")
        for uid, rows in by_user.items():
            field = effective_rate_for_user(rows, today)
            if field is None:
                skipped_zero += 1; continue
            pence = to_pence_per_hour(field)
            if pence is None or pence <= 0:
                skipped_zero += 1; continue
            await conn.execute("""
              INSERT INTO staff_meta (user_external_id, hourly_rate_pence, source, rate_observed_at)
              VALUES ($1, $2, 'tanda', now())
              ON CONFLICT (user_external_id) DO UPDATE SET
                hourly_rate_pence = EXCLUDED.hourly_rate_pence,
                source            = 'tanda',
                rate_observed_at  = now(),
                updated_at        = now()
              WHERE staff_meta.source IN ('tanda','unset')
            """, uid, pence)
            written += 1

    await conn.close()
    print(f"upserted {written} staff_meta rows  ({skipped_zero} skipped — no current rate or zero)")

asyncio.run(main())
PYEOF
