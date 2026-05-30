#!/usr/bin/env python3
"""Weather sync: 300 day backfill + 7 day forecast. Run daily via cron."""
import os, json, urllib.request, urllib.parse, asyncio, asyncpg
from datetime import date, timedelta, datetime as _dt

PG_DSN = os.environ["PG_DSN"]
LAT, LON = 50.6620, -4.7530
BASE = "https://api.open-meteo.com/v1/forecast"
ARCHIVE = "https://archive-api.open-meteo.com/v1/archive"
DAILY = ["rain_sum","temperature_2m_max","temperature_2m_min","temperature_2m_mean","wind_speed_10m_max","sunshine_duration"]
FC_EXTRA = ["weather_code","precipitation_probability_max","sunrise","sunset"]

def fetch(url, start, end, extra=None):
    fields = list(DAILY) + (extra or [])
    qs = urllib.parse.urlencode({"latitude":LAT,"longitude":LON,"start_date":start.isoformat(),"end_date":end.isoformat(),"daily":",".join(fields),"timezone":"Europe/London","wind_speed_unit":"mph","temperature_unit":"celsius","precipitation_unit":"mm"})
    return json.loads(urllib.request.urlopen(f"{url}?{qs}", timeout=15).read())

async def main():
    conn = await asyncpg.connect(PG_DSN)
    today = date.today()

    # Backfill 300 days of actuals (idempotent - ON CONFLICT handles dupes)
    start = today - timedelta(days=300)
    end = today - timedelta(days=1)
    print(f"Backfill actuals {start} to {end}")
    data = fetch(ARCHIVE, start, end)
    days = data.get("daily", {})
    dates = days.get("time", [])
    count = 0
    for i, d in enumerate(dates):
        obs = date.fromisoformat(d)
        try:
            await conn.execute("""
                INSERT INTO weather_daily (observation_date, hours_sunshine, rain_mm, avg_temp_c, peak_temp_c, min_temp_c, max_wind_mph, source, raw_payload)
                VALUES ($1,$2,$3,$4,$5,$6,$7,'open-meteo',$8::jsonb)
                ON CONFLICT (observation_date) DO NOTHING
            """, obs,
                round(days.get("sunshine_duration",[0])[i]/3600,1) if days.get("sunshine_duration",[0])[i] else None,
                days.get("rain_sum",[None])[i], days.get("temperature_2m_mean",[None])[i],
                days.get("temperature_2m_max",[None])[i], days.get("temperature_2m_min",[None])[i],
                int(days.get("wind_speed_10m_max",[0])[i]) if days.get("wind_speed_10m_max",[0])[i] else None,
                json.dumps({k: days.get(k,[None]*len(dates))[i] for k in DAILY}))
            count += 1
        except Exception as e:
            print(f"  skip {obs}: {e}")
    print(f"  {count} actuals inserted")

    # 7-day forecast
    fc = today + timedelta(days=7)
    print(f"Forecast {today} to {fc}")
    fdata = fetch(BASE, today, fc, extra=FC_EXTRA)
    fdays = fdata.get("daily", {})
    fdates = fdays.get("time", [])
    fcount = 0
    for i, d in enumerate(fdates):
        fd = date.fromisoformat(d)
        try:
            await conn.execute("""
                INSERT INTO weather_forecast (forecast_date, rain_mm, max_temp_c, min_temp_c, max_wind_mph, weather_code, precipitation_probability, raw_payload, sunrise, sunset)
                VALUES ($1,$2,$3,$4,$5,$6,$7,$8::jsonb,$9,$10)
                ON CONFLICT (forecast_date, fetched_at) DO NOTHING
            """, fd,
                fdays.get("rain_sum",[None])[i], fdays.get("temperature_2m_max",[None])[i],
                fdays.get("temperature_2m_min",[None])[i],
                int(fdays.get("wind_speed_10m_max",[0])[i]) if fdays.get("wind_speed_10m_max",[0])[i] else None,
                int(fdays.get("weather_code",[0])[i]) if fdays.get("weather_code",[0])[i] else None,
                int(fdays.get("precipitation_probability_max",[0])[i]) if fdays.get("precipitation_probability_max",[0])[i] else None,
                json.dumps({k: fdays.get(k,[None]*len(fdates))[i] for k in DAILY+FC_EXTRA}),
                _dt.fromisoformat(fdays.get("sunrise",[None])[i]) if fdays.get("sunrise",[None])[i] else None,
                _dt.fromisoformat(fdays.get("sunset",[None])[i]) if fdays.get("sunset",[None])[i] else None)
            fcount += 1
        except Exception as e:
            print(f"  skip forecast {fd}: {e}")
    print(f"  {fcount} forecast days inserted")

    await conn.close()
    print("Done")

asyncio.run(main())
