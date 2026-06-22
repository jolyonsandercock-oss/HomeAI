#!/usr/bin/env python3
"""Fetch historical weather data from Open-Meteo for Newquay, Cornwall.

Batch-fetches daily data (temp, rain, sunshine, sunrise/sunset) and
writes to Postgres `weather_daily` table. Safe to re-run (UPSERT).

Usage: python3 fetch_weather.py [--from YYYY-MM-DD] [--to YYYY-MM-DD]
"""
import os, sys, json, asyncio, httpx, asyncpg
from datetime import date, timedelta

LAT, LON = 50.4155, -5.0732  # Newquay
PG_DSN = os.environ.get("PG_DSN", "")
BATCH_SIZE = 365  # Open-Meteo allows up to ~366 days per call

DAILY_PARAMS = [
    "temperature_2m_max", "temperature_2m_min", "temperature_2m_mean",
    "precipitation_sum", "rain_sum",
    "sunshine_duration", "daylight_duration",
    "sunrise", "sunset",
]


def daterange(start, end):
    for n in range((end - start).days + 1):
        yield start + timedelta(n)


async def fetch_batch(client, start_dt, end_dt):
    url = "https://archive-api.open-meteo.com/v1/archive"
    params = {
        "latitude": LAT,
        "longitude": LON,
        "start_date": start_dt.isoformat(),
        "end_date": end_dt.isoformat(),
        "daily": ",".join(DAILY_PARAMS),
        "timezone": "Europe/London",
    }
    resp = await client.get(url, params=params, timeout=30)
    resp.raise_for_status()
    return resp.json()


def parse_daily(data):
    """Parse Open-Meteo JSON into row dicts matching existing schema."""
    daily = data.get("daily", {})
    rows = []
    for i, dt_str in enumerate(daily.get("time", [])):
        from datetime import datetime
        # sunrise/sunset come as ISO datetime strings, parse to datetime objects
        sunrise_str = daily.get("sunrise", [None])[i]
        sunset_str = daily.get("sunset", [None])[i]
        sunrise_dt = datetime.fromisoformat(sunrise_str) if sunrise_str else None
        sunset_dt = datetime.fromisoformat(sunset_str) if sunset_str else None
        row = {
            "observation_date": date.fromisoformat(dt_str),
            "peak_temp_c": daily.get("temperature_2m_max", [None])[i],
            "min_temp_c": daily.get("temperature_2m_min", [None])[i],
            "avg_temp_c": daily.get("temperature_2m_mean", [None])[i],
            "rain_mm": daily.get("precipitation_sum", [None])[i],
            "hours_sunshine": (
                round(daily["sunshine_duration"][i] / 3600, 1)
                if daily.get("sunshine_duration", [None])[i] is not None
                else None
            ),
            "sunrise": sunrise_dt,
            "sunset": sunset_dt,
            "raw_payload": json.dumps(daily.get("rain_sum", [None])[i]),
        }
        rows.append(row)
    return rows


async def upsert_weather(pool, rows):
    async with pool.acquire() as conn:
        await conn.execute("SET LOCAL app.current_entity = '1'")
        await conn.execute("SET LOCAL app.current_realm = 'shared'")
        for r in rows:
            await conn.execute(
                """INSERT INTO weather_daily
                   (observation_date, peak_temp_c, min_temp_c, avg_temp_c,
                    rain_mm, hours_sunshine,
                    sunrise, sunset, raw_payload, source)
                   VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb,'open-meteo')
                   ON CONFLICT (observation_date) DO UPDATE SET
                     peak_temp_c = EXCLUDED.peak_temp_c,
                     min_temp_c = EXCLUDED.min_temp_c,
                     avg_temp_c = EXCLUDED.avg_temp_c,
                     rain_mm = EXCLUDED.rain_mm,
                     hours_sunshine = EXCLUDED.hours_sunshine,
                     sunrise = EXCLUDED.sunrise,
                     sunset = EXCLUDED.sunset,
                     raw_payload = EXCLUDED.raw_payload""",
                r["observation_date"],
                r["peak_temp_c"],
                r["min_temp_c"],
                r["avg_temp_c"],
                r["rain_mm"],
                r["hours_sunshine"],
                r["sunrise"],
                r["sunset"],
                r.get("raw_payload", "{}"),
            )


async def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--from", dest="from_date", default="2021-01-01")
    parser.add_argument("--to", dest="to_date", default=date.today().isoformat())
    args = parser.parse_args()

    start = date.fromisoformat(args.from_date)
    end = date.fromisoformat(args.to_date)

    # Check existing
    pool = await asyncpg.create_pool(PG_DSN, min_size=1, max_size=2)
    async with pool.acquire() as conn:
        rows = await conn.fetch("SELECT observation_date FROM weather_daily")
    existing = {r["observation_date"] for r in rows}

    all_dates = [d for d in daterange(start, end)]
    missing = [d for d in all_dates if d not in existing]
    if not missing:
        print(f"All {len(existing)} dates already in DB. Nothing to fetch.")
        await pool.close()
        return

    print(f"Existing: {len(existing)} weather dates in DB")
    print(f"Fetching: {len(missing)} dates ({missing[0]} to {missing[-1]})")

    # Batch into chunks
    chunks = []
    chunk = []
    for d in missing:
        chunk.append(d)
        if len(chunk) >= BATCH_SIZE:
            chunks.append(chunk)
            chunk = []
    if chunk:
        chunks.append(chunk)
    print(f"Batches: {len(chunks)}")

    async with httpx.AsyncClient() as client:
        for i, chunk in enumerate(chunks):
            s, e = chunk[0], chunk[-1]
            print(f"  [{i+1}/{len(chunks)}] {s} to {e} ...", end=" ", flush=True)
            try:
                data = await fetch_batch(client, s, e)
                parsed = parse_daily(data)
                await upsert_weather(pool, parsed)
                print(f"{len(parsed)} rows written")
            except Exception as ex:
                print(f"FAIL: {ex}")

    await pool.close()
    print("Done.")

asyncio.run(main())
