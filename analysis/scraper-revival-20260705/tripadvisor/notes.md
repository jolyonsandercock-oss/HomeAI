# TripAdvisor (review_listings rows) — diagnosis 2026-07-05

## What this scraper is
Same skeleton as Google (see ../google-reviews/notes.md):
`scripts/u133-scrape-reviews.py`, not scheduled in any cron (confirmed via
`crontab -l` + `scripts/crontab.canonical.txt`), last ran 2026-05-21 against
the two `review_listings` rows (tripadvisor/restaurant,
tripadvisor/hotel), both `last_status='fetch_fail'`.

## Repro (1 read-only fetch per listing_url — 2 total, zero logins)
Fetched both listing_url values from the DB with the scraper's own UA
string:
- `.../Restaurant_Review-g186245-d1536289-...Tintagel...html` -> **HTTP 403
  Forbidden**
- `.../Hotel_Review-g186245-d677960-...Tintagel...html` -> **HTTP 403
  Forbidden**

Both error bodies (saved: tripadvisor_restaurant-ERROR-403.html,
tripadvisor_hotel-ERROR-403.html) are a **DataDome bot-challenge page**:
```
<p id="cmsg">Please enable JS and disable any ad blocker</p>
...host':'geo.captcha-delivery.com'...
```
This is enterprise-grade anti-bot tooling (DataDome), not a simple
UA/header check — confirms the task's own hypothesis exactly ("likely
bot-blocked (403/challenge)"). Per the hard safety rules, this is a wall to
document, not fight (no CAPTCHA-solving, no stealth-browser arms race
attempted).

## The real, live pipeline is elsewhere and is healthy
Actual TripAdvisor guest reviews are ingested from real TripAdvisor
notification emails via inline SQL in `scripts/u163-reviews-simple.sh`
(regex-parses "N-bubble review" subjects + quoted review text), run every
3h. Verified in `guest_reviews`: source='tripadvisor' has 16 rows, most
recent `posted_at` = 2026-06-28. Checked whether that's a stale pipeline or
just no new reviews: the `emails` table has 57 tripadvisor-domain emails in
the last 30 days (as recent as 2026-07-04), but nearly all are marketing
notifications ("Diners keep eyeing your listing", "June performance
report") that correctly do NOT match the review-detection filter
(subject ILIKE '%review%' OR '%bubble%'). The one genuine review email in
that window ("Look at you with that 5-bubble review!", 2026-06-28) *was*
captured. So 2026-06-28 is not staleness — it is the correct, current state:
no new TripAdvisor reviews have arrived since then. The ops freshness
registry backs this: `reviews_scrape` = ok (age 1.1h, SLA 6h) — that job
covers the email-based ingest, and it's running clean.

The `/app/reviews` dashboard (V287 `reviews_source_health`) already
documents "tripadvisor fetch_fail" as a known, accepted dead-scraper state,
same as Google.

## Login attempts used this session: 0

## Verdict: STRUCTURALLY-BLOCKED (bot wall) — no fix applied, no further
action recommended
TripAdvisor's public review pages are behind DataDome; a plain-HTTP or even
a vanilla headless-Playwright fetch will keep getting the same 403/challenge
without stealth tooling that is out of scope here. The pipeline this was
meant to feed (`guest_reviews`, source=tripadvisor) is already served by the
live email-notification parser and is healthy/current. No cron references
this scraper, so nothing regressed — it was already dead and already
superseded before this session.

Optional (not actioned, Jo's call): set `review_listings.active=false` for
both tripadvisor rows to stop them showing as "fetch_fail" in the dashboard
join — cosmetic only.
