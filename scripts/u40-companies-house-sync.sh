#!/bin/bash
# /home_ai/scripts/u40-companies-house-sync.sh
#
# Weekly Companies House sync for entities with a `companies_house_number`.
# Free API — no auth needed (Bearer with empty token if asked).
# Per SPEC §7.5.
#
# Cron candidate: 0 4 * * 1  (Mondays 04:00)
#
# Setup: UPDATE entities SET companies_house_number = '<num>' WHERE id IN (1, 2);

set -euo pipefail

docker exec -i homeai-playwright python <<'PYEOF'
import os, json, urllib.request, urllib.error, base64, asyncio, asyncpg
from datetime import datetime, date

PG_DSN = os.environ["PG_DSN"]
BASE   = "https://api.company-information.service.gov.uk"


def ch_get(company_number):
    """Companies House public API — no auth header required for read."""
    req = urllib.request.Request(f"{BASE}/company/{company_number}",
                                  headers={"Accept": "application/json"})
    try:
        r = urllib.request.urlopen(req, timeout=15)
        return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return {"_error": f"HTTP {e.code}: {e.reason}"}
    except Exception as e:
        return {"_error": str(e)[:200]}


def parse_date(s):
    if not s: return None
    try: return datetime.strptime(s, "%Y-%m-%d").date()
    except ValueError: return None


async def main():
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_entity='all'")

    entities = await conn.fetch("""
      SELECT id, name, companies_house_number
        FROM entities
       WHERE companies_house_number IS NOT NULL
    """)
    print(f"entities with CH numbers: {len(entities)}")
    if not entities:
        print("(no entities have companies_house_number set. UPDATE entities SET companies_house_number='<num>' WHERE id IN (1,2);)")
        await conn.close()
        return

    new_alerts = 0
    for e in entities:
        cn = e["companies_house_number"]
        data = ch_get(cn)
        if "_error" in data:
            print(f"  ✗ entity {e['id']} ({e['name']}) [{cn}]: {data['_error']}")
            continue

        addr = data.get("registered_office_address") or {}
        acc  = data.get("accounts") or {}
        cs   = data.get("confirmation_statement") or {}

        accounts_next_due  = parse_date(acc.get("next_due"))
        confirm_next_due   = parse_date(cs.get("next_due"))
        accounts_last      = parse_date(acc.get("last_accounts", {}).get("made_up_to") if isinstance(acc.get("last_accounts"), dict) else None)
        confirm_last       = parse_date(cs.get("last_made_up_to"))

        await conn.execute("""
          INSERT INTO companies_house_log
            (company_number, name, status, registered_address,
             accounts_next_due_date, accounts_last_made_up_to,
             confirmation_statement_next_due_date, confirmation_statement_last_made_up_to,
             raw_payload)
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        """, cn, data.get("company_name"), data.get("company_status"),
             json.dumps(addr), accounts_next_due, accounts_last,
             confirm_next_due, confirm_last, json.dumps(data))

        today = date.today()
        for alert_type, due in [("accounts_due", accounts_next_due), ("confirmation_due", confirm_next_due)]:
            if not due: continue
            days_until = (due - today).days
            if days_until > 30: continue
            # Idempotent: only INSERT if no open alert for this tuple
            inserted = await conn.fetchval("""
              INSERT INTO companies_house_alerts
                (entity_id, company_number, alert_type, due_date, days_until)
              VALUES ($1, $2, $3, $4, $5)
              ON CONFLICT (entity_id, alert_type, due_date) DO NOTHING
              RETURNING id
            """, e["id"], cn, alert_type, due, days_until)
            if inserted:
                new_alerts += 1
                print(f"  ⚠ ALERT: {e['name']} {alert_type} due in {days_until}d ({due})")

        print(f"  ✓ {e['name']} [{cn}] — accounts due {accounts_next_due}, confirmation due {confirm_next_due}")

    await conn.close()
    print(f"\ndone. new alerts: {new_alerts}")

asyncio.run(main())
PYEOF
