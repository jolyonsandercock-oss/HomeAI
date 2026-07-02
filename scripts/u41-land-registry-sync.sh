#!/bin/bash
# /home_ai/scripts/u41-land-registry-sync.sh
#
# Monthly Land Registry Price Paid sync.
# Free API, no auth. CSV response.
# Per SPEC §7.6.
#
# Cron: 0 4 1 * *  (1st of month, 04:00)
#
# Setup: INSERT INTO properties (entity_id, postcode, address, acquisition_date, acquisition_price_gbp)
#        VALUES (2, 'PL34 0DA', 'Tintagel address...', '2019-08-15', 195000);
#        (×7 for Jo's portfolio)

set -euo pipefail
DAYS_BACK="${1:-90}"

docker exec -i -e DAYS_BACK="$DAYS_BACK" homeai-playwright python <<'PYEOF'
import os, urllib.request, urllib.error, csv, io, asyncio, asyncpg, json
from datetime import datetime, date, timedelta

PG_DSN = os.environ["PG_DSN"]
DAYS_BACK = int(os.environ.get("DAYS_BACK", "90"))
BASE = "https://landregistry.data.gov.uk/app/ppd/ppd_data.csv"


def fetch_sales(postcode, since):
    """Fetch sales CSV for a postcode area. Returns list of dicts."""
    qs = f"?postcode={urllib.parse.quote(postcode)}&from={since.strftime('%Y-%m-%d')}"
    req = urllib.request.Request(f"{BASE}{qs}", headers={"Accept": "text/csv"})
    try:
        r = urllib.request.urlopen(req, timeout=30)
        body = r.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        return None, f"HTTP {e.code}"
    except Exception as e:
        return None, str(e)[:120]
    # Land Registry CSV has a header row.
    reader = csv.DictReader(io.StringIO(body))
    rows = []
    for r in reader:
        # Map the fields we care about. Land Registry columns:
        # 'Transaction unique identifier','Price','Date of Transfer','Postcode',
        # 'Property Type','Old/New','Duration','PAON','SAON','Street','Locality',
        # 'Town/City','District','County','PPD Category Type','Record Status'
        try:
            price = float(r.get("Price") or 0)
            d = r.get("Date of Transfer", "")[:10]  # 'YYYY-MM-DD HH:MM' → date
            rows.append({
                "date": d,
                "price": price,
                "postcode": r.get("Postcode"),
                "type": r.get("Property Type"),
                "tenure": r.get("Duration"),
                "address": " ".join(filter(None, [r.get("PAON"), r.get("SAON"), r.get("Street")]))
            })
        except ValueError:
            continue
    return rows, None


import urllib.parse

async def main():
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_entity='all'")

    properties = await conn.fetch("""
      SELECT id, postcode,
             COALESCE(address_line1, '') AS address,
             purchase_price AS acquisition_price_gbp
        FROM properties WHERE postcode IS NOT NULL ORDER BY id
    """)
    print(f"properties to check: {len(properties)}")
    if not properties:
        print("(no properties seeded with a postcode. INSERT INTO properties (entity_id, postcode, address_line1, town, purchase_date, purchase_price) VALUES (2, '<PC>', '<addr>', '<town>', '<YYYY-MM-DD>', <price>);)")
        await conn.close()
        return

    since = date.today() - timedelta(days=DAYS_BACK)
    inserted = 0
    for p in properties:
        sales, err = fetch_sales(p["postcode"], since)
        if err:
            print(f"  ✗ property {p['id']} ({p['postcode']}): {err}")
            continue
        avg = sum(s["price"] for s in sales) / len(sales) if sales else None
        await conn.execute("""
          INSERT INTO property_market_log (property_id, sales, avg_price, sample_n)
          VALUES ($1, $2, $3, $4)
        """, p["id"], json.dumps(sales), round(avg, 2) if avg else None, len(sales))
        delta = None
        if avg and p["acquisition_price_gbp"]:
            delta = round(100 * (avg - float(p["acquisition_price_gbp"])) / float(p["acquisition_price_gbp"]), 1)
        delta_str = f"{delta:+.1f}%" if delta is not None else "—"
        print(f"  ✓ {p['postcode']:12s}  n={len(sales):3d}  avg=£{int(avg) if avg else 0:>7,}  vs acquisition: {delta_str}")
        inserted += 1

    await conn.close()
    print(f"\ndone. {inserted} snapshots inserted.")

asyncio.run(main())
PYEOF
