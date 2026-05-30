# Run this on JolyBox to fix sunset/sunrise + sales data
# Usage: bash /home_ai/scripts/fix-sun-and-sales.sh

echo "=== PHASE 1: Backfill 300 days sunrise/sunset ==="
docker exec homeai-bot-responder python3 << 'PYEOF'
import os, json, urllib.request, urllib.parse, asyncio, asyncpg
from datetime import date, timedelta, datetime as _dt

PG_DSN = os.environ["PG_DSN"]
LAT, LON = 50.6620, -4.7530
ARCHIVE = "https://archive-api.open-meteo.com/v1/archive"

today = date.today()
start = today - timedelta(days=300)
end = today - timedelta(days=1)

qs = urllib.parse.urlencode({
    "latitude": LAT, "longitude": LON,
    "start_date": start.isoformat(), "end_date": end.isoformat(),
    "daily": "sunrise,sunset",
    "timezone": "Europe/London",
})
url = f"{ARCHIVE}?{qs}"
data = json.loads(urllib.request.urlopen(url, timeout=30).read())
days = data.get("daily", {})
dates = days.get("time", [])

conn = await asyncpg.connect(PG_DSN)
count = 0
for i, d in enumerate(dates):
    obs = date.fromisoformat(d)
    sr = days.get("sunrise", [None]*len(dates))[i]
    ss = days.get("sunset",  [None]*len(dates))[i]
    try:
        await conn.execute("""
            INSERT INTO weather_daily (observation_date, source, sunrise, sunset, realm)
            VALUES ($1, 'open-meteo', $2::timestamptz, $3::timestamptz, 'shared')
            ON CONFLICT (observation_date) DO UPDATE SET
                sunrise = COALESCE(EXCLUDED.sunrise, weather_daily.sunrise),
                sunset  = COALESCE(EXCLUDED.sunset,  weather_daily.sunset)
        """, obs, _dt.fromisoformat(sr) if sr else None,
             _dt.fromisoformat(ss) if ss else None)
        count += 1
    except Exception as e:
        print(f"  skip {obs}: {e}")

await conn.close()
print(f"Sunrise/sunset: {count} days backfilled")
PYEOF

echo ""
echo "=== PHASE 2: Extend sales backfill to 300 days ==="
docker exec homeai-bot-responder python3 << 'PYEOF'
import asyncio, asyncpg, os, sys
PG_DSN = os.environ["PG_DSN"]

MAP = {
    2: ("gross_sales", float), 1: ("net_sales", float),
    4: ("cash_total", float), 6: ("card_total", float),
    19: ("covers", float), 18: ("gratuities", float),
    14: ("refunds", float), 16: ("voids", float),
    50: ("accommodation_sales", float),
}
SITE_ENTITY = {"malthouse": 1, "sandwich": 2}

async def run():
    conn = await asyncpg.connect(PG_DSN)
    dates = await conn.fetch("""
        SELECT DISTINCT site, report_date FROM touchoffice_fixed_totals
        WHERE site IN ('malthouse','sandwich')
        ORDER BY report_date DESC
    """)
    total = 0
    for r in dates:
        site, dt = r["site"], r["report_date"]
        ent = SITE_ENTITY[site]
        key = f"to-epos-bridge-{site}-{dt}"
        totals = await conn.fetch("""
            SELECT totaliser_id, value FROM touchoffice_fixed_totals
            WHERE site=$1 AND report_date=$2
        """, site, dt)
        vals = {k: 0 for k in ["gross_sales","net_sales","cash_total",
                "card_total","covers","gratuities","refunds","voids",
                "accommodation_sales"]}
        for t in totals:
            tid, val = t["totaliser_id"], t["value"]
            if tid in MAP and val is not None:
                col, fn = MAP[tid]
                vals[col] = fn(val) if val else 0
        await conn.execute("""
            INSERT INTO epos_daily_reports
                (report_date, session, gross_sales, net_sales,
                 cash_total, card_total, covers, gratuities,
                 refunds, voids, accommodation_sales,
                 idempotency_key, created_at, entity_id, realm)
            VALUES ($1,'day',$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,NOW(),$12,'work')
            ON CONFLICT (idempotency_key) DO UPDATE SET
                gross_sales=EXCLUDED.gross_sales,
                net_sales=EXCLUDED.net_sales,
                cash_total=EXCLUDED.cash_total,
                card_total=EXCLUDED.card_total,
                covers=EXCLUDED.covers,
                gratuities=EXCLUDED.gratuities,
                refunds=EXCLUDED.refunds,
                voids=EXCLUDED.voids,
                accommodation_sales=EXCLUDED.accommodation_sales
        """, dt, vals["gross_sales"], vals["net_sales"],
             vals["cash_total"], vals["card_total"],
             int(vals["covers"]), vals["gratuities"],
             vals["refunds"], vals["voids"],
             vals["accommodation_sales"], key, ent)
        total += 1
    await conn.close()
    print(f"Sales: {total} rows upserted")
asyncio.run(run())
PYEOF

echo ""
echo "=== PHASE 3: Verify ==="
docker exec homeai-postgres psql -U postgres -d homeai -c "
SELECT 'sunrise' as type, count(*) FROM weather_daily WHERE sunrise IS NOT NULL
UNION ALL
SELECT 'sunset', count(*) FROM weather_daily WHERE sunset IS NOT NULL
UNION ALL
SELECT 'epos_malthouse', count(*) FROM epos_daily_reports WHERE entity_id=1
UNION ALL
SELECT 'epos_sandwich', count(*) FROM epos_daily_reports WHERE entity_id=2;
" 2>&1

echo "Done!"