#!/bin/bash
# /home_ai/scripts/u46-weather-daily.sh
#
# Daily weather sync for PL34 0DA (Tintagel, Cornwall).
# Source: Open-Meteo (https://open-meteo.com) — free, no auth, UK-accurate.
#
# Pulls:
#   - yesterday's actuals (rain, sunshine, temp, wind) → weather_daily
#   - next-5-days forecast → weather_forecast
#   - Telegram alert immediately on any forecast day with severe conditions
#
# Cron: 30 7 * * *  (daily 07:30 — after the daily TouchOffice scrape at 03:00,
#                    so we can join sales-vs-weather in the same digest)

set -uo pipefail

docker exec -i homeai-playwright python <<'PYEOF'
import os, json, urllib.request, urllib.parse, asyncio, asyncpg
from datetime import date, timedelta

PG_DSN = os.environ["PG_DSN"]

# Tintagel coordinates (PL34 0DA)
LAT = 50.6620
LON = -4.7530

BASE = "https://api.open-meteo.com/v1/forecast"
ARCHIVE = "https://archive-api.open-meteo.com/v1/archive"
MARINE = "https://marine-api.open-meteo.com/v1/marine"

DAILY_FIELDS = [
    "rain_sum",
    "temperature_2m_max",
    "temperature_2m_min",
    "temperature_2m_mean",
    "wind_speed_10m_max",
    "sunshine_duration",
]

# Forecast-only extras u109 needs: WMO code + rain probability
FORECAST_EXTRA_FIELDS = ["weather_code", "precipitation_probability_max"]

MARINE_FIELDS = ["wave_height_max", "wave_period_max", "wave_direction_dominant"]


def fetch_daily(start, end, base=BASE, extra_fields=None):
    fields = list(DAILY_FIELDS) + list(extra_fields or [])
    qs = urllib.parse.urlencode({
        "latitude": LAT, "longitude": LON,
        "start_date": start.isoformat(), "end_date": end.isoformat(),
        "daily": ",".join(fields),
        "timezone": "Europe/London",
        "wind_speed_unit": "mph",
        "temperature_unit": "celsius",
        "precipitation_unit": "mm",
    })
    r = urllib.request.urlopen(f"{base}?{qs}", timeout=15)
    return json.loads(r.read())


def fetch_marine(start, end):
    qs = urllib.parse.urlencode({
        "latitude": LAT, "longitude": LON,
        "start_date": start.isoformat(), "end_date": end.isoformat(),
        "daily": ",".join(MARINE_FIELDS),
        "timezone": "Europe/London",
    })
    try:
        r = urllib.request.urlopen(f"{MARINE}?{qs}", timeout=15)
        return json.loads(r.read())
    except Exception as e:
        print(f"  marine fetch failed: {e}")
        return {}


def severity_categories(rain_mm, max_temp, max_wind):
    """Returns alert tags for severe forecast days."""
    tags = []
    if rain_mm and rain_mm >= 10: tags.append("heavy_rain")
    if max_wind and max_wind >= 35: tags.append("high_wind")
    if max_temp and max_temp >= 20: tags.append("heat_over_20")
    return tags


async def main():
    conn = await asyncpg.connect(PG_DSN)
    today = date.today()

    # ── Backfill any missing actuals from the last 30 days ──
    earliest = today - timedelta(days=30)
    latest_in_db = await conn.fetchval(
      "SELECT MAX(observation_date) FROM weather_daily")
    if latest_in_db:
        start = max(latest_in_db + timedelta(days=1), earliest)
    else:
        start = earliest
    end_actuals = today - timedelta(days=1)  # archive only has up to yesterday

    if start <= end_actuals:
        print(f"backfilling actuals {start} → {end_actuals}")
        data = fetch_daily(start, end_actuals, base=ARCHIVE)
        days   = data.get("daily", {})
        dates  = days.get("time", [])
        for i, d in enumerate(dates):
            obs = date.fromisoformat(d)
            rain = days.get("rain_sum", [None]*len(dates))[i]
            tmax = days.get("temperature_2m_max", [None]*len(dates))[i]
            tmin = days.get("temperature_2m_min", [None]*len(dates))[i]
            tavg = days.get("temperature_2m_mean", [None]*len(dates))[i]
            wmax = days.get("wind_speed_10m_max", [None]*len(dates))[i]
            sun_s = days.get("sunshine_duration", [None]*len(dates))[i]
            sun_h = round(sun_s / 3600.0, 1) if sun_s is not None else None
            day_payload = {
                "rain": rain, "tmax": tmax, "tmin": tmin, "tavg": tavg,
                "wmax_mph": wmax, "sun_h": sun_h,
            }
            await conn.execute("""
              INSERT INTO weather_daily
                (observation_date, hours_sunshine, rain_mm, avg_temp_c, peak_temp_c, min_temp_c, max_wind_mph, source, raw_payload)
              VALUES ($1, $2, $3, $4, $5, $6, $7, 'open-meteo', $8::jsonb)
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
                 json.dumps(day_payload))
        print(f"  upserted {len(dates)} actuals")

    # ── 5-day forecast (+marine) ──
    fc_end = today + timedelta(days=5)
    print(f"fetching forecast {today} → {fc_end}")
    fc_data = fetch_daily(today, fc_end, base=BASE, extra_fields=FORECAST_EXTRA_FIELDS)
    days   = fc_data.get("daily", {})
    dates  = days.get("time", [])

    # Marine — Trebarwith Strand approximation (same lat/lon as weather)
    marine_data = fetch_marine(today, fc_end)
    m_days = marine_data.get("daily", {}) if marine_data else {}
    m_dates = m_days.get("time", []) if m_days else []
    marine_by_date = {}
    for i, d in enumerate(m_dates):
        marine_by_date[d] = {
            "h": m_days.get("wave_height_max",      [None]*len(m_dates))[i],
            "p": m_days.get("wave_period_max",      [None]*len(m_dates))[i],
            "dir": m_days.get("wave_direction_dominant", [None]*len(m_dates))[i],
        }

    alerts = []
    for i, d in enumerate(dates):
        fd = date.fromisoformat(d)
        rain = days.get("rain_sum", [None]*len(dates))[i]
        tmax = days.get("temperature_2m_max", [None]*len(dates))[i]
        tmin = days.get("temperature_2m_min", [None]*len(dates))[i]
        wmax = days.get("wind_speed_10m_max", [None]*len(dates))[i]
        wcode = days.get("weather_code", [None]*len(dates))[i]
        pp   = days.get("precipitation_probability_max", [None]*len(dates))[i]
        m    = marine_by_date.get(d, {})
        cats = severity_categories(rain, tmax, wmax)
        await conn.execute("""
          INSERT INTO weather_forecast
            (forecast_date, rain_mm, max_temp_c, min_temp_c, max_wind_mph,
             alert_categories, raw_payload,
             weather_code, precipitation_probability,
             wave_height_m, wave_period_s, wave_direction_deg)
          VALUES ($1, $2, $3, $4, $5, $6::text[], $7::jsonb,
                  $8, $9, $10, $11, $12)
          ON CONFLICT (forecast_date, fetched_at) DO NOTHING
        """, fd, rain, tmax, tmin,
             int(wmax) if wmax is not None else None,
             cats,
             json.dumps({"rain": rain, "tmax": tmax, "tmin": tmin,
                         "wmax_mph": wmax, "code": wcode, "rain_prob": pp,
                         "wave_h": m.get("h"), "wave_p": m.get("p"),
                         "wave_dir": m.get("dir")}),
             int(wcode) if wcode is not None else None,
             int(pp)    if pp    is not None else None,
             m.get("h"), m.get("p"),
             int(m["dir"]) if m.get("dir") is not None else None)
        if cats:
            alerts.append((fd, cats, rain, tmax, wmax))

    print(f"forecast: {len(dates)} days, {len(alerts)} alerts, "
          f"marine: {len(marine_by_date)} days")

    # Telegram alert summary if anything severe in forecast
    if alerts:
        lines = ["🌦 Weather alerts — next 5 days (PL34 0DA):"]
        for fd, cats, rain, tmax, wmax in alerts:
            parts = []
            if "heavy_rain"  in cats: parts.append(f"rain {rain:.0f}mm")
            if "high_wind"   in cats: parts.append(f"wind {wmax:.0f}mph")
            if "heat_over_20" in cats: parts.append(f"max {tmax:.0f}°C")
            lines.append(f"  • {fd.strftime('%a %d %b')}: {' · '.join(parts)}")
        # Write to a file the host script can pick up
        with open("/tmp/u46-weather-alert.txt", "w") as f:
            f.write("\n".join(lines))

    await conn.close()

asyncio.run(main())
PYEOF

# Ferry alert through notify-telegram on the host
MSG=$(docker exec homeai-playwright sh -c 'test -f /tmp/u46-weather-alert.txt && cat /tmp/u46-weather-alert.txt; rm -f /tmp/u46-weather-alert.txt' 2>/dev/null)
if [[ -n "$MSG" ]]; then
  bash /home_ai/.claude/scripts/notify-telegram.sh "$MSG" "weather" >/dev/null 2>&1 || true
fi
