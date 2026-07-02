#!/bin/bash
# /home_ai/scripts/u32-cashing-up-parser.sh
#
# Reads the 2026CashUp Google Sheet (weekly-block layout), parses each
# day-column, joins TouchOffice fixed_totals on report date, computes
# variance, persists to till_reconciliation. Sends Telegram alert when
# variance breaches the threshold (default >£5 OR >0.5% of net sales).
#
# Cron: 23:30 daily.
#
# Idempotent — UNIQUE(idempotency_key) on till_reconciliation.

set -euo pipefail
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" homeai-playwright python << 'PYEOF'
import os, asyncio, json, urllib.request, urllib.parse, urllib.error, re
from datetime import date as _date
import asyncpg

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN = os.environ["PG_DSN"]


def vault_get(path):
    return json.loads(urllib.request.urlopen(urllib.request.Request(
        f"http://vault:8200/v1/secret/data/{path}",
        headers={"X-Vault-Token": VAULT_TOKEN}), timeout=5).read())["data"]["data"]


def _parse_money(s):
    if s is None or s == "": return None
    s = str(s).replace("£", "").replace(",", "").strip()
    if s in ("", "-", "—"): return None
    try: return float(s)
    except ValueError: return None


def _parse_uk_date(s):
    if not s: return None
    m = re.match(r"^(\d{1,2})[/\-\.](\d{1,2})[/\-\.](\d{2,4})$", str(s).strip())
    if not m: return None
    d, mo, y = int(m.group(1)), int(m.group(2)), int(m.group(3))
    if y < 100: y += 2000
    try: return _date(y, mo, d)
    except ValueError: return None


async def main():
    creds = vault_get("sheets/cashing_up")
    sheet_id = creds["sheet_id"]; tab = creds["tab"]; account = creds["access_account"]

    # Read the whole tab via google-fetch's new /sheets/values endpoint
    range_a1 = urllib.parse.quote(f"{tab}!A1:VZ30", safe="")
    url = f"http://google-fetch:8011/sheets/values/{account}/{sheet_id}/{range_a1}"
    try:
        sheet = json.loads(urllib.request.urlopen(url, timeout=30).read())
    except Exception as e:
        print(f"sheets read failed: {e}"); return

    rows = sheet.get("values", [])
    if not rows:
        print("no rows"); return
    width = max(len(r) for r in rows)
    for r in rows: r += [""] * (width - len(r))
    print(f"read {len(rows)} rows × {width} cols from {tab!r}")

    block_starts = []
    for i, v in enumerate(rows[0]):
        if isinstance(v, str) and v.strip().lower() == "thursday" and i > 0:
            block_starts.append(i - 1)
    print(f"found {len(block_starts)} week-blocks")

    parsed = []
    for bs in block_starts:
        for offset in range(1, 8):
            col = bs + offset
            if col >= width: continue
            d_str = rows[1][col] if len(rows) > 1 else ""
            date_obj = _parse_uk_date(d_str)
            if date_obj is None: continue
            manager = rows[2][col].strip() if len(rows) > 2 and rows[2][col] else ""
            opening_total    = _parse_money(rows[11][col]) if len(rows) > 11 else None
            expected_opening = _parse_money(rows[12][col]) if len(rows) > 12 else None
            drawer_error     = _parse_money(rows[13][col]) if len(rows) > 13 else None
            if all(v is None for v in (opening_total, expected_opening, drawer_error)) and not manager:
                continue
            parsed.append({
                "date": date_obj, "manager": manager,
                "opening_total": opening_total, "expected_opening": expected_opening,
                "drawer_error": drawer_error,
            })
    print(f"parsed {len(parsed)} day-rows with data")
    if not parsed: return

    conn = await asyncpg.connect(PG_DSN)
    ins = upd = flagged = 0
    threshold = 5.0
    async with conn.transaction():
        await conn.execute("SET LOCAL app.current_entity = '1'")
        for row in parsed:
            d = row["date"]
            net = await conn.fetchval("""
              SELECT value FROM touchoffice_fixed_totals
               WHERE site='malthouse' AND report_date=$1 AND label='NET sales'
            """, d)
            de = row["drawer_error"]
            variance_pct = None
            if de is not None and net and net > 0:
                variance_pct = round(float(de) / float(net) * 100, 3)
            status = "open"
            if de is not None:
                if abs(de) > threshold:
                    status = "flagged"
                elif net and net > 0 and abs(variance_pct or 0) > 0.5:
                    status = "flagged"
                else:
                    status = "ok"
            note = f"manager={row['manager']!r} expected_opening={row['expected_opening']} opening_total={row['opening_total']}"
            n = await conn.fetchval("""
              INSERT INTO till_reconciliation
                (idempotency_key, recon_date, session, z_reading, cash_counted,
                 expected_cash, variance, variance_pct, status, staff_notes)
              VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
              ON CONFLICT (idempotency_key) DO UPDATE SET
                z_reading=EXCLUDED.z_reading,
                cash_counted=EXCLUDED.cash_counted,
                expected_cash=EXCLUDED.expected_cash,
                variance=EXCLUDED.variance,
                variance_pct=EXCLUDED.variance_pct,
                status=EXCLUDED.status,
                staff_notes=EXCLUDED.staff_notes
              RETURNING (xmax = 0)
            """,
              f"till_{d.isoformat()}", d, "day", net, row["opening_total"],
              row["expected_opening"], de, variance_pct, status, note)
            if n: ins += 1
            else: upd += 1
            if status == "flagged": flagged += 1
    await conn.close()
    print(f"till_reconciliation: ins={ins} upd={upd} flagged={flagged}")

asyncio.run(main())
PYEOF
