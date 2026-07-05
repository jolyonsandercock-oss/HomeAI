# Google reviews (review_listings row) — diagnosis 2026-07-05

## What "review_listings" actually is
`scripts/u133-scrape-reviews.py` — an early, explicitly-labelled SKELETON
("These are intentionally minimal stubs... graceful no-op if a source can't
be parsed, set last_status='unparsed'") that reads `review_listings`, fetches
each listing_url with plain `urllib`, and hands the HTML to a per-source
parser. It is **not scheduled in any cron** — confirmed via `crontab -l` and
`scripts/crontab.canonical.txt`: only `u133-scrape-tides.py` is scheduled;
`u133-scrape-reviews.py` and its sibling `u163-reviews-scrape.py` are not
referenced anywhere in the live crontab. `review_listings.last_scraped_at`
for the google/malthouse row is 2026-05-21 — it hasn't run since, and nothing
will ever invoke it again as things stand.

## Repro (1 read-only fetch, zero logins)
Fetched the exact listing_url from the DB row:
`https://www.google.com/travel/search?q=malthouse tintagel google reviews&hl=en-GB&gl=uk&cs=1&ssta=1`
-> HTTP 200, 1,340,297 bytes, `<title>Google Travel</title>`, only **3**
occurrences of the string "review" in the whole page (saved:
google.html). This confirms `parse_google()`'s stub (`return []`, by
design/comment) isn't missing a selector — the configured URL is a Google
Travel *search* page, not a Maps/Business-Profile reviews page, and simply
doesn't carry meaningful review content to parse in the first place.

## The real, live pipeline is elsewhere and is healthy
Google reviews are actually ingested by `scripts/u278-google-reviews.py`
(parses Google Business Profile email notifications from
businessprofile-noreply@google.com), run every 3h from
`scripts/u163-reviews-simple.sh`. Verified in `guest_reviews`:
`source='google'` has 33 rows, most recent `posted_at` = **2026-07-05
16:41** (today). The ops freshness registry already reflects this as
healthy: `ops.check_freshness()` → `reviews_scrape` status=`ok`,
age_hours=1.1, sla_hours=6.

The `/app/reviews` dashboard (migration V287, `reviews_source_health` slug)
already documents this exact situation in its own description: "dead
scrapers (google unparsed, tripadvisor fetch_fail) and scraper-less sources
... all surface" — i.e. this was a known, accepted, already-diagnosed state
before this session, not a live regression.

## Login attempts used this session: 0

## Verdict: STRUCTURALLY-BLOCKED / already superseded — no fix applied
Not touching `u133-scrape-reviews.py` or the `review_listings` row: it's
dead code pointed at the wrong URL type for an abandoned approach, and the
thing it was meant to produce (fresh Google reviews in `guest_reviews`) is
already delivered by a different, live, verified-healthy pipeline. Building
a real Google Maps/Business-Profile scraper here would be net-new work
duplicating something that already works — out of scope for "revive the
dead scraper."

Optional (not actioned, Jo's call): `review_listings.active` could be set
to `false` for the google/malthouse row so it stops being listed as a "dead
scraper" in the dashboard's FULL JOIN — purely cosmetic, no functional
change, since `reviews_source_health` already keys review counts off
`guest_reviews`, not this table.
