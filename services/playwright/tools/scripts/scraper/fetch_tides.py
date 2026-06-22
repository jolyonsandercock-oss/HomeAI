#!/usr/bin/env python3
"""Fetch historical tide predictions for Newlyn (proxy for Newquay).

Uses tidepredict to generate daily high/low tide data for a date range
and writes to Postgres `tide_daily` table. Safe to re-run (UPSERT).

Usage: python3 fetch_tides.py [--from YYYY-MM-DD] [--to YYYY-MM-DD]
"""
import os, sys, subprocess, re, asyncio, asyncpg
from datetime import date, timedelta

LOCATION = "Newlyn"
PG_DSN = os.environ.get("PG_DSN", "")
BATCH_MONTHS = 12  # tidepredict handles ~1 year per call reliably


def daterange(start, end):
    for n in range((end - start).days + 1):
        yield start + timedelta(n)


def months_batch(start, end):
    """Yield (batch_start, batch_end) tuples of ~BATCH_MONTHS each."""
    cur = start
    while cur < end:
        # Advance by BATCH_MONTHS
        y = cur.year + (cur.month + BATCH_MONTHS - 1) // 12
        m = (cur.month + BATCH_MONTHS - 1) % 12 + 1
        batch_end = min(date(y, m, 1) - timedelta(days=1), end)
        yield (cur, batch_end)
        cur = batch_end + timedelta(days=1)


def run_tidepredict(start_dt, end_dt):
    """Run tidepredict and return list of parsed CSV rows."""
    cmd = [
        sys.executable, "-m", "tidepredict",
        "-l", LOCATION,
        "-b", start_dt.strftime("%Y-%m-%d 00:00"),
        "-e", end_dt.strftime("%Y-%m-%d 23:59"),
        "-f", "c",  # CSV format
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)

    if result.returncode != 0:
        print(f"  tidepredict error: {result.stderr[:200]}", flush=True)
        return []

    rows = []
    for line in result.stdout.strip().split("\n"):
        line = line.strip()
        if not line or line.startswith("#") or not line.startswith(LOCATION):
            continue
        parts = line.split(",")
        if len(parts) < 6:
            continue
        try:
            loc = parts[0].strip()
            dt_str = parts[1].strip()
            tm_str = parts[2].strip()
            tz = parts[3].strip()
            height = float(parts[4].strip())
            state = parts[5].strip().strip('"')
            rows.append({
                "date": date.fromisoformat(dt_str),
                "time": tm_str,
                "height": height,
                "state": state,
            })
        except (ValueError, IndexError):
            continue
    return rows


def fmt_time(tm_str):
    """Convert HHMM or HH:MM[:SS] to a datetime.time object."""
    from datetime import time
    if not tm_str:
        return None
    tm_str = tm_str.strip()
    if ":" in tm_str:
        parts = tm_str.split(":")
        return time(int(parts[0]), int(parts[1]), int(parts[2]) if len(parts) > 2 else 0)
    # HHMM format
    if len(tm_str) == 4:
        return time(int(tm_str[:2]), int(tm_str[2:]))
    return None


def collapse_to_daily(tide_rows):
    """Collapse list of tide events into daily rows with 2 highs + 2 lows."""
    from collections import defaultdict
    by_date = defaultdict(list)
    for r in tide_rows:
        by_date[r["date"]].append(r)

    daily = []
    for dt in sorted(by_date.keys()):
        events = by_date[dt]
        highs = sorted([e for e in events if e["state"] == "High Tide"], key=lambda x: x["time"])
        lows = sorted([e for e in events if e["state"] == "Low Tide"], key=lambda x: x["time"])

        row = {"report_date": dt}
        for i, h in enumerate(highs[:2]):
            row[f"high_tide_{i+1}_time"] = fmt_time(h["time"])
            row[f"high_tide_{i+1}_height"] = h["height"]
        for i, l in enumerate(lows[:2]):
            row[f"low_tide_{i+1}_time"] = fmt_time(l["time"])
            row[f"low_tide_{i+1}_height"] = l["height"]
        daily.append(row)
    return daily


async def upsert_tides(pool, rows):
    async with pool.acquire() as conn:
        await conn.execute("SET LOCAL app.current_entity = '1'")
        await conn.execute("SET LOCAL app.current_realm = 'work'")
        for r in rows:
            await conn.execute(
                """INSERT INTO tide_daily
                   (report_date, high_tide_1_time, high_tide_1_height,
                    low_tide_1_time, low_tide_1_height,
                    high_tide_2_time, high_tide_2_height,
                    low_tide_2_time, low_tide_2_height)
                   VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
                   ON CONFLICT (report_date) DO UPDATE SET
                     high_tide_1_time = EXCLUDED.high_tide_1_time,
                     high_tide_1_height = EXCLUDED.high_tide_1_height,
                     low_tide_1_time = EXCLUDED.low_tide_1_time,
                     low_tide_1_height = EXCLUDED.low_tide_1_height,
                     high_tide_2_time = EXCLUDED.high_tide_2_time,
                     high_tide_2_height = EXCLUDED.high_tide_2_height,
                     low_tide_2_time = EXCLUDED.low_tide_2_time,
                     low_tide_2_height = EXCLUDED.low_tide_2_height""",
                r["report_date"],
                r.get("high_tide_1_time"),
                r.get("high_tide_1_height"),
                r.get("low_tide_1_time"),
                r.get("low_tide_1_height"),
                r.get("high_tide_2_time"),
                r.get("high_tide_2_height"),
                r.get("low_tide_2_time"),
                r.get("low_tide_2_height"),
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
        rows = await conn.fetch("SELECT report_date FROM tide_daily")
    existing = {r["report_date"] for r in rows}

    all_dates = [d for d in daterange(start, end)]
    missing = [d for d in all_dates if d not in existing]
    if not missing:
        print(f"All {len(existing)} tide dates already in DB. Nothing to fetch.")
        await pool.close()
        return

    print(f"Existing: {len(existing)} tide dates in DB")
    print(f"Fetching: {len(missing)} dates ({missing[0]} to {missing[-1]})")

    # Batch into month chunks
    batches = list(months_batch(missing[0], missing[-1]))
    print(f"Batches: {len(batches)}")

    for i, (s, e) in enumerate(batches):
        print(f"  [{i+1}/{len(batches)}] {s} to {e} ...", end=" ", flush=True)
        try:
            tide_rows = run_tidepredict(s, e)
            if not tide_rows:
                print("no data returned")
                continue
            daily = collapse_to_daily(tide_rows)
            await upsert_tides(pool, daily)
            print(f"{len(daily)} days written ({len(tide_rows)} events)")
        except Exception as ex:
            print(f"FAIL: {ex}")

    await pool.close()
    print("Done.")

asyncio.run(main())
