#!/usr/bin/env python3
"""
U163 — Playwright-based reviews scraper.

Replaces u133-scrape-reviews.py (which used urllib + got 403'd on
TripAdvisor and had a stub Google parser).

Walks review_listings, scrapes each listing's public reviews page via
Playwright (headless Chromium with realistic UA), parses recent reviews,
upserts into guest_reviews keyed by (source, review_id).

Designed to run inside the homeai-playwright container which has
playwright + asyncpg.
"""
import asyncio
import asyncpg
import hashlib
import os
import re
import sys

import urllib.parse

from playwright.async_api import async_playwright

PG_DSN = os.environ["PG_DSN"]

USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/130.0.0.0 Safari/537.36"
)


async def fetch_listings(conn):
    return await conn.fetch(
        """SELECT source, location, listing_url FROM review_listings
           WHERE active = true ORDER BY source, location"""
    )


async def scrape_tripadvisor(page, listing):
    """Return list of review dicts from a TripAdvisor restaurant/hotel page."""
    print(f"  → {listing['listing_url']}")
    try:
        await page.goto(listing["listing_url"], wait_until="domcontentloaded", timeout=45000)
        await page.wait_for_timeout(3000)
    except Exception as e:
        print(f"    goto failed: {e}")
        return []

    # TripAdvisor uses a few different review-card classes; try each.
    reviews = []
    selectors = [
        '[data-test-target="reviews-tab"] [data-reviewid]',  # restaurant
        '[data-test-target="HR_CC_CARD"]',                  # hotel reviews
        'div[data-test-target*="review"]',
    ]
    cards = []
    for sel in selectors:
        cards = await page.query_selector_all(sel)
        if cards:
            print(f"    found {len(cards)} cards via {sel}")
            break
    if not cards:
        # Save diagnostic
        print(f"    no review cards — saved diagnostic /tmp/u163-{listing['source']}-{listing['location']}.html")
        html = await page.content()
        open(f"/tmp/u163-{listing['source']}-{listing['location']}.html", "w").write(html)
        return []

    for card in cards[:20]:
        try:
            review_id = await card.get_attribute("data-reviewid") or \
                        await card.get_attribute("id") or \
                        hashlib.md5((await card.inner_text())[:200].encode()).hexdigest()[:16]

            # Rating: look for aria-label with "of 5 bubbles" or "stars"
            rating = None
            r_el = await card.query_selector('[aria-label*="of 5"], [class*="bubble_"]')
            if r_el:
                aria = await r_el.get_attribute("aria-label") or ""
                m = re.search(r"(\d+\.?\d*)\s+of\s+5", aria)
                if m:
                    rating = int(float(m.group(1)))
                else:
                    cls = (await r_el.get_attribute("class") or "")
                    m = re.search(r"bubble_(\d)0", cls)
                    if m:
                        rating = int(m.group(1))

            # Reviewer name
            name_el = await card.query_selector('[class*="reviewerInfo"] a, [data-test-target*="reviewer"]')
            reviewer = (await name_el.inner_text()).strip() if name_el else None

            # Body
            body_el = await card.query_selector('[class*="reviewText"], q, span[class*="QewHA"]')
            body = (await body_el.inner_text()).strip() if body_el else None
            if body:
                body = body[:2000]

            # Posted_at: look for date-like text
            date_el = await card.query_selector('[class*="ratingDate"], time, span[class*="postedDate"]')
            posted_text = (await date_el.inner_text()).strip() if date_el else None

            reviews.append({
                "review_id":  review_id,
                "source":     listing["source"],
                "location":   listing["location"],
                "rating":     rating,
                "reviewer_name": reviewer,
                "body":       body,
                "posted_text": posted_text,
                "review_url": listing["listing_url"],
            })
        except Exception as e:
            print(f"    card parse err: {e}")
            continue

    print(f"    parsed {len(reviews)} reviews")
    return reviews


async def scrape_google(page, listing):
    """Google reviews are tricky — the /travel/search URL renders client-side
    via JS. Wait for the reviews panel + scrape DOM cards."""
    print(f"  → {listing['listing_url']}")
    try:
        await page.goto(listing["listing_url"], wait_until="networkidle", timeout=45000)
        await page.wait_for_timeout(5000)  # let JS settle
    except Exception as e:
        print(f"    goto failed: {e}")
        return []

    # Try a few selector patterns for Google review cards
    reviews = []
    for sel in [
        '[data-review-id]',
        'div[jscontroller][data-review-content]',
        '[role="article"][aria-label*="review"]',
    ]:
        cards = await page.query_selector_all(sel)
        if cards:
            print(f"    found {len(cards)} cards via {sel}")
            for card in cards[:20]:
                try:
                    rid = await card.get_attribute("data-review-id") or \
                          hashlib.md5((await card.inner_text())[:200].encode()).hexdigest()[:16]
                    text = await card.inner_text()
                    # rating: look for "★" count or "5 stars" pattern
                    rating = None
                    m = re.search(r"(\d)\s*star", text, re.I)
                    if m:
                        rating = int(m.group(1))
                    else:
                        m = re.search(r"^[★⭐]+", text)
                        if m:
                            rating = min(5, len(m.group(0)))

                    body = text[:1000] if text else None
                    reviews.append({
                        "review_id":  rid,
                        "source":     listing["source"],
                        "location":   listing["location"],
                        "rating":     rating,
                        "reviewer_name": None,
                        "body":       body,
                        "posted_text": None,
                        "review_url": listing["listing_url"],
                    })
                except Exception as e:
                    print(f"    parse err: {e}")
            break

    if not reviews:
        html = await page.content()
        open(f"/tmp/u163-{listing['source']}-{listing['location']}.html", "w").write(html)
        print(f"    no Google reviews parsed — saved /tmp/u163-{listing['source']}-{listing['location']}.html")
    return reviews


async def upsert_reviews(conn, reviews):
    inserted = 0
    skipped = 0
    for r in reviews:
        # Map listing 'restaurant'/'hotel' → 'malthouse' per location check constraint
        loc = r["location"]
        if loc in ("restaurant", "hotel"):
            loc = "malthouse"
        try:
            await conn.execute("SET app.current_entity = 'all'")
            await conn.execute("SELECT home_ai.set_realm('work')")
            res = await conn.execute(
                """INSERT INTO guest_reviews
                     (review_id, source, location, rating, reviewer_name, body,
                      posted_at, review_url, status, realm)
                   VALUES ($1, $2, $3, $4, $5, $6, NULL, $7, 'new', 'work')
                   ON CONFLICT (source, review_id) DO UPDATE SET
                     rating = EXCLUDED.rating,
                     body   = COALESCE(EXCLUDED.body, guest_reviews.body),
                     scraped_at = NOW()""",
                r["review_id"], r["source"], loc, r["rating"],
                r["reviewer_name"], r["body"], r["review_url"]
            )
            if "INSERT" in res:
                inserted += 1
            else:
                skipped += 1
        except Exception as e:
            print(f"    upsert err for {r['review_id']}: {e}")
    return inserted, skipped


async def main():
    conn = await asyncpg.connect(PG_DSN)
    listings = await fetch_listings(conn)
    print(f"-- {len(listings)} active review_listings")

    summary = {"total_seen": 0, "inserted": 0, "skipped": 0, "errors": 0}

    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=True,
            args=['--no-sandbox', '--disable-dev-shm-usage']
        )
        ctx = await browser.new_context(
            user_agent=USER_AGENT,
            viewport={"width": 1400, "height": 900},
            locale="en-GB",
            extra_http_headers={"Accept-Language": "en-GB,en;q=0.9"},
        )
        page = await ctx.new_page()

        for L in listings:
            print(f"\n── {L['source']} / {L['location']}")
            try:
                if L["source"] == "tripadvisor":
                    rev = await scrape_tripadvisor(page, L)
                elif L["source"] == "google":
                    rev = await scrape_google(page, L)
                else:
                    print(f"  unknown source {L['source']!r}")
                    continue
            except Exception as e:
                print(f"  scrape error: {e}")
                summary["errors"] += 1
                continue
            summary["total_seen"] += len(rev)
            ins, sk = await upsert_reviews(conn, rev)
            summary["inserted"] += ins
            summary["skipped"]  += sk

        await ctx.close()
        await browser.close()

    print(f"\n== summary: {summary}")
    await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
