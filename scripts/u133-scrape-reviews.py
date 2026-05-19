#!/usr/bin/env python3
"""u133-scrape-reviews.py — daily review harvest for guest_reviews.

Reads listing URLs from `review_listings` table (one row per
source × location), fetches the public review page, extracts review
records, and upserts into `guest_reviews` keyed on `(source, review_id)`.

This is a SKELETON that handles fetch + parse stubs per source.
Google Maps / TripAdvisor / Booking.com all bot-detect aggressive
clients — production parsing may need Playwright + per-source CSS
selectors that evolve. For now: graceful no-op if a source can't be
parsed, set `last_status='unparsed'` so the next iteration knows.

Run on the host: python3 /home_ai/scripts/u133-scrape-reviews.py
"""
from __future__ import annotations
import argparse
import json
import re
import subprocess
import sys
import time
import urllib.request
import urllib.error

UA = "homeai-review-scraper/1.0 (+https://jolybox.tailc27dff.ts.net)"


def psql(sql: str, *, capture: bool = False) -> str:
    cmd = ["docker", "exec", "-i", "homeai-postgres",
           "psql", "-U", "postgres", "-d", "homeai",
           "-v", "ON_ERROR_STOP=1", "-tA"]
    p = subprocess.run(cmd, input=sql, text=True, capture_output=True)
    if p.returncode != 0:
        print(f"[psql FAIL] {p.stderr.strip()}", file=sys.stderr)
        sys.exit(p.returncode)
    return p.stdout if capture else ""


def fetch(url: str) -> str | None:
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": UA,
            "Accept-Language": "en-GB,en;q=0.9",
            "Accept": "text/html,application/xhtml+xml",
        })
        with urllib.request.urlopen(req, timeout=25) as r:
            return r.read().decode("utf-8", errors="replace")
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as e:
        print(f"  [fetch FAIL] {url}: {e}", file=sys.stderr)
        return None


# ---------------------------------------------------------------------------
# Per-source parsers. Each takes raw HTML and returns a list of dicts:
#   { review_id, rating, reviewer_name, body, posted_at, review_url }
#
# These are intentionally minimal stubs. Real production extraction needs:
#   - Playwright (JS rendering for Google + Booking.com)
#   - CSS-selector maintenance per source's HTML drift
#   - Rate-limit + cookie-jar handling
# For now, the skeleton ships so listing URLs + frontend + cron are wired;
# parser bodies get expanded as needed when a specific source is being
# pulled in.
# ---------------------------------------------------------------------------

def parse_google(html: str, listing_url: str) -> list[dict]:
    # Google Maps SSR HTML embeds reviews in `window.APP_INITIALIZATION_STATE`
    # JSON blobs. Detection is fragile; defer real implementation to a
    # Playwright pass when Google is being targeted in earnest.
    return []


def parse_tripadvisor(html: str, listing_url: str) -> list[dict]:
    # TripAdvisor markup uses data-test-target attributes per review card.
    # Server-rendered for the first page; needs Playwright for "Show more".
    return []


def parse_booking_com(html: str, listing_url: str) -> list[dict]:
    # Booking.com guest reviews are paginated via a separate /reviews/list
    # endpoint that returns JSON when the right headers are sent. Skeleton
    # leaves the body extraction to a follow-up.
    return []


PARSERS = {
    "google":      parse_google,
    "tripadvisor": parse_tripadvisor,
    "booking_com": parse_booking_com,
}


def sql_escape(s: str | None) -> str:
    if s is None:
        return "NULL"
    return "'" + s.replace("'", "''") + "'"


def upsert_review(source: str, location: str, r: dict) -> str:
    return f"""INSERT INTO guest_reviews
        (review_id, source, location, rating, reviewer_name, body, posted_at,
         scraped_at, raw_payload, status, review_url, realm)
        VALUES (
            {sql_escape(r['review_id'])},
            {sql_escape(source)},
            {sql_escape(location)},
            {r.get('rating') if r.get('rating') is not None else 'NULL'},
            {sql_escape(r.get('reviewer_name'))},
            {sql_escape(r.get('body'))},
            {sql_escape(r.get('posted_at'))}::timestamptz,
            NOW(),
            {sql_escape(json.dumps(r))}::jsonb,
            'new',
            {sql_escape(r.get('review_url'))},
            'work'
        )
        ON CONFLICT (source, review_id) DO UPDATE
           SET rating        = EXCLUDED.rating,
               body          = EXCLUDED.body,
               posted_at     = EXCLUDED.posted_at,
               scraped_at    = NOW(),
               raw_payload   = EXCLUDED.raw_payload,
               review_url    = EXCLUDED.review_url;"""


def update_listing_status(source: str, location: str, status: str, count: int) -> str:
    return f"""UPDATE review_listings
                  SET last_scraped_at = NOW(),
                      last_status     = {sql_escape(status)},
                      notes           = COALESCE(notes,'') || E'\\n' ||
                                        to_char(NOW(),'YYYY-MM-DD HH24:MI') ||
                                        ' — ' || {sql_escape(status)} ||
                                        ' ({count} rows)'
                WHERE source = {sql_escape(source)}
                  AND location = {sql_escape(location)};"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only-source", help="e.g. google / tripadvisor / booking_com")
    args = ap.parse_args()

    where = "active = true"
    if args.only_source:
        where += f" AND source = {sql_escape(args.only_source)}"
    listings = psql(
        f"SELECT source, location, listing_url FROM review_listings WHERE {where}",
        capture=True,
    ).strip()
    if not listings:
        print("-- no active listings in review_listings — nothing to scrape")
        print("-- to add a listing:")
        print("   docker exec -i homeai-postgres psql -U postgres -d homeai -c \\")
        print("     \"INSERT INTO review_listings (source, location, listing_url) VALUES ('google','malthouse','<url>');\"")
        return

    total = 0
    for line in listings.splitlines():
        source, location, listing_url = line.split("|", 2)
        parser = PARSERS.get(source)
        if not parser:
            print(f"  [SKIP] {source} {location} — no parser registered")
            continue
        html = fetch(listing_url)
        if html is None:
            psql(update_listing_status(source, location, "fetch_fail", 0))
            continue
        reviews = parser(html, listing_url)
        if not reviews:
            psql(update_listing_status(source, location, "unparsed", 0))
            print(f"  [-] {source} {location} — parser returned 0 (stub or genuine empty)")
            continue
        for r in reviews:
            psql(upsert_review(source, location, r))
        psql(update_listing_status(source, location, "ok", len(reviews)))
        total += len(reviews)
        print(f"  [OK] {source} {location} — {len(reviews)} reviews upserted")
        time.sleep(1.0)

    print(f"-- total reviews upserted: {total}")


if __name__ == "__main__":
    main()
