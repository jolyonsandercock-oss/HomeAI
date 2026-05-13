#!/bin/bash
# /home_ai/scripts/u47-weather-backfill.sh
#
# One-shot: backfill 400 days of historical weather for PL34 0DA via Open-Meteo
# archive endpoint. Idempotent — re-runs upsert by observation_date.
#
# Use cases:
#   - First population of weather_daily beyond the 30-day window u46 created.
#   - Re-pull if Open-Meteo updates an old reading.

set -uo pipefail
DAYS="${1:-400}"

docker exec -i -e DAYS="$DAYS" homeai-playwright python <<'PYEOF'
import os, json, urllib.request, urllib.parse, asyncio, asyncpg
from datetime import date, timedelta

PG_DSN = os.environ["PG_DSN"]
DAYS   = int(os.environ.get("DAYS", "400"))

LAT = 50.6620
LON = -4.7530
ARCHIVE = "https://archive-api.open-meteo.com/v1/archive"

FIELDS = [
  "rain_sum","temperature_2m_max","temperature_2m_min",
  "temperature_2m_mean","wind_speed_10m_max","sunshine_duration",
]

async def main():
    conn = await asyncpg.connect(PG_DSN)
    end   = date.today() - timedelta(days=1)
    start = end - timedelta(days=DAYS-1)
    qs = urllib.parse.urlencode({
        "latitude": LAT, "longitude": LON,
        "start_date": start.isoformat(), "end_date": end.isoformat(),
        "daily": ",".join(FIELDS),
        "timezone": "Europe/London",
        "wind_speed_unit": "mph",
        "temperature_unit": "celsius",
        "precipitation_unit": "mm",
    })
    print(f"fetching {start} → {end} ({DAYS}d)")
    r = urllib.request.urlopen(f"{ARCHIVE}?{qs}", timeout=30)
    data = json.loads(r.read())
    days  = data.get("daily", {})
    dates = days.get("time", [])
    print(f"  api returned {len(dates)} rows")

    upserted = 0
    for i, d in enumerate(dates):
        obs = date.fromisoformat(d)
        rain  = days.get("rain_sum",          [None]*len(dates))[i]
        tmax  = days.get("temperature_2m_max",[None]*len(dates))[i]
        tmin  = days.get("temperature_2m_min",[None]*len(dates))[i]
        tavg  = days.get("temperature_2m_mean",[None]*len(dates))[i]
        wmax  = days.get("wind_speed_10m_max",[None]*len(dates))[i]
        sun_s = days.get("sunshine_duration", [None]*len(dates))[i]
        sun_h = round(sun_s / 3600.0, 1) if sun_s is not None else None
        payload = {"rain":rain,"tmax":tmax,"tmin":tmin,"tavg":tavg,
                   "wmax_mph":wmax,"sun_h":sun_h}
        await conn.execute("""
          INSERT INTO weather_daily
            (observation_date, hours_sunshine, rain_mm, avg_temp_c,
             peak_temp_c, min_temp_c, max_wind_mph, source, raw_payload)
          VALUES ($1,$2,$3,$4,$5,$6,$7,'open-meteo',$8::jsonb)
          ON CONFLICT (observation_date) DO UPDATE SET
            hours_sunshine = EXCLUDED.hours_sunshine,
            rain_mm        = EXCLUDED.rain_mm,
            avg_temp_c     = EXCLUDED.avg_temp_c,
            peak_temp_c    = EXCLUDED.peak_temp_c,
            min_temp_c     = EXCLUDED.min_temp_c,
            max_wind_mph   = EXCLUDED.max_wind_mph,
            raw_payload    = EXCLUDED.raw_payload
        """, obs, sun_h, rain, tavg, tmax, tmin,
             int(wmax) if wmax is not None else None,
             json.dumps(payload))
        upserted += 1

    total = await conn.fetchval("SELECT COUNT(*) FROM weather_daily")
    span  = await conn.fetchrow("SELECT MIN(observation_date), MAX(observation_date) FROM weather_daily")
    print(f"  upserted: {upserted}")
    print(f"  weather_daily now holds {total} rows, span {span[0]} → {span[1]}")
    await conn.close()

asyncio.run(main())
PYEOF
