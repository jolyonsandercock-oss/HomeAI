import os, json, urllib.request, urllib.parse, asyncio, asyncpg
from datetime import date, timedelta, datetime as _dt

async def main():
    PG_DSN = os.environ["PG_DSN"]
    LAT, LON = 50.662, -4.753
    today = date.today()
    conn = await asyncpg.connect(PG_DSN)

    # 300 days sunrise/sunset
    start = today - timedelta(days=300)
    end = today - timedelta(days=1)
    qs = urllib.parse.urlencode({"latitude":LAT,"longitude":LON,"start_date":start.isoformat(),"end_date":end.isoformat(),"daily":"sunrise,sunset","timezone":"Europe/London"})
    data = json.loads(urllib.request.urlopen("https://archive-api.open-meteo.com/v1/archive?"+qs, timeout=30).read())
    days = data["daily"]
    dates = days["time"]
    c = 0
    for i, d in enumerate(dates):
        sr = days["sunrise"][i]; ss = days["sunset"][i]
        try:
            await conn.execute(
                "INSERT INTO weather_daily (observation_date,source,sunrise,sunset,realm) VALUES ($1,'open-meteo',$2::timestamptz,$3::timestamptz,'shared') ON CONFLICT (observation_date) DO UPDATE SET sunrise=COALESCE(EXCLUDED.sunrise,weather_daily.sunrise),sunset=COALESCE(EXCLUDED.sunset,weather_daily.sunset)",
                date.fromisoformat(d),
                _dt.fromisoformat(sr) if sr else None,
                _dt.fromisoformat(ss) if ss else None)
            c += 1
        except Exception as e:
            pass
    print(f"Sunrise/sunset: {c} days")

    # Extend sales backfill
    MAP = {2:("gross_sales",float),1:("net_sales",float),4:("cash_total",float),6:("card_total",float),19:("covers",float),18:("gratuities",float),14:("refunds",float),16:("voids",float),50:("accommodation_sales",float)}
    SITE_ENTITY = {"malthouse":1,"sandwich":2}
    rows = await conn.fetch("SELECT DISTINCT site, report_date FROM touchoffice_fixed_totals WHERE site IN ('malthouse','sandwich') ORDER BY report_date")
    s = 0
    for r in rows:
        site, dt, ent = r["site"], r["report_date"], SITE_ENTITY[r["site"]]
        key = f"to-epos-bridge-{site}-{dt}"
        totals = await conn.fetch("SELECT totaliser_id, value FROM touchoffice_fixed_totals WHERE site=$1 AND report_date=$2", site, dt)
        v = {k:0 for k in ["gross_sales","net_sales","cash_total","card_total","covers","gratuities","refunds","voids","accommodation_sales"]}
        for t in totals:
            if t["totaliser_id"] in MAP and t["value"]:
                col, fn = MAP[t["totaliser_id"]]
                v[col] = fn(t["value"])
        await conn.execute(
            "INSERT INTO epos_daily_reports (report_date,session,gross_sales,net_sales,cash_total,card_total,covers,gratuities,refunds,voids,accommodation_sales,idempotency_key,created_at,entity_id,realm) VALUES ($1,'day',$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,NOW(),$12,'work') ON CONFLICT (idempotency_key) DO UPDATE SET gross_sales=EXCLUDED.gross_sales,net_sales=EXCLUDED.net_sales,cash_total=EXCLUDED.cash_total,card_total=EXCLUDED.card_total,covers=EXCLUDED.covers,gratuities=EXCLUDED.gratuities,refunds=EXCLUDED.refunds,voids=EXCLUDED.voids,accommodation_sales=EXCLUDED.accommodation_sales",
            dt, v["gross_sales"],v["net_sales"],v["cash_total"],v["card_total"],int(v["covers"]),v["gratuities"],v["refunds"],v["voids"],v["accommodation_sales"],key,ent)
        s += 1
    print(f"Sales: {s} rows")
    await conn.close()

asyncio.run(main())
