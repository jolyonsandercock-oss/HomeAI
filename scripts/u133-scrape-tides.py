#!/usr/bin/env python3
"""u133-scrape-tides.py — weekly tide scrape for Boscastle.

Hits https://www.tidetimes.org.uk/boscastle-tide-times-YYYYMMDD once per day
for today + the next 6 days. Parses the visible (`vis2`) rows of the tide
table on each page. Idempotent upsert into `tide_times` via `docker exec psql`.

Designed for a Sunday-06:00 cron — covers Mon-Sun.

Run on the host: python3 /home_ai/scripts/u133-scrape-tides.py [--days N]
"""
from __future__ import annotations
import argparse
import datetime as dt
import re
import subprocess
import sys
import time
import urllib.request
import urllib.error

UA = "homeai-tide-scraper/1.0 (+https://jolybox.tailc27dff.ts.net)"
URL_TEMPLATE = "https://www.tidetimes.org.uk/boscastle-tide-times-{date}"

ROW_RE = re.compile(
    r'<tr class="vis2">\s*'
    r'<td class="tal">(High|Low)</td>\s*'
    r'<td class="tac"><span>(\d{2}):(\d{2})</span></td>\s*'
    r'<td class="tar">([0-9.]+)m</td>',
    re.IGNORECASE,
)


def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "text/html"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read().decode("utf-8", errors="replace")


def parse_day(html: str) -> list[tuple[str, str, float]]:
    out = []
    for hl, hh, mm, height in ROW_RE.findall(html):
        out.append((hl.lower(), f"{hh}:{mm}", float(height)))
    return out


def upsert_sql(tide_date: dt.date, rows: list[tuple[str, str, float]]) -> str:
    if not rows:
        return ""
    values = ",\n".join(
        f"('{tide_date.isoformat()}', '{hl}', '{tt}'::time, {ht}, 'boscastle', 'tidetimes.org.uk', NOW(), 'work')"
        for hl, tt, ht in rows
    )
    return f"""INSERT INTO tide_times (tide_date, high_low, tide_time, height_m, location, source, scraped_at, realm)
VALUES
{values}
ON CONFLICT (location, tide_date, tide_time) DO UPDATE
   SET high_low   = EXCLUDED.high_low,
       height_m   = EXCLUDED.height_m,
       scraped_at = NOW();"""


def run_sql(sql: str) -> None:
    if not sql:
        return
    p = subprocess.run(
        ["docker", "exec", "-i", "homeai-postgres",
         "psql", "-U", "postgres", "-d", "homeai", "-v", "ON_ERROR_STOP=1", "-q"],
        input=sql, text=True, capture_output=True,
    )
    if p.returncode != 0:
        print(f"  [FAIL] psql exited {p.returncode}: {p.stderr.strip()}", file=sys.stderr)
        sys.exit(p.returncode)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=7, help="how many days to scrape from today")
    args = ap.parse_args()

    today = dt.date.today()
    total = 0
    sql_batch = []
    for offset in range(args.days):
        d = today + dt.timedelta(days=offset)
        url = URL_TEMPLATE.format(date=d.strftime("%Y%m%d"))
        try:
            html = fetch(url)
        except urllib.error.URLError as e:
            print(f"  [WARN] {d.isoformat()} fetch failed: {e}", file=sys.stderr)
            continue
        rows = parse_day(html)
        if not rows:
            print(f"  [WARN] {d.isoformat()} parsed 0 rows from {url}", file=sys.stderr)
            continue
        sql_batch.append(upsert_sql(d, rows))
        total += len(rows)
        summary = ", ".join(f"{r[0][:1].upper()} {r[1]}" for r in rows)
        print(f"  [OK ] {d.isoformat()} {len(rows)} tide rows ({summary})")
        time.sleep(0.5)  # be polite

    run_sql("\n".join(sql_batch))
    print(f"-- total tide rows upserted: {total}")


if __name__ == "__main__":
    main()
