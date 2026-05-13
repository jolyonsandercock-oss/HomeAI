# review-scraper

Scrapes Google Business + TripAdvisor reviews for the Malthouse (pub) and
Sandwich shop. Inserts new reviews into `guest_reviews` for the drafter
(`u39-review-drafter.sh`) to pick up.

**Status: STUB** — full Playwright implementation pending. Until then,
`u39-insert-review-manual.sh` accepts reviews via SQL INSERT for any path
(manual paste, ad-hoc Selenium run on a laptop, etc).

## Why a stub

Google Business reviews require either:
- A signed-in browser session (cookies + 2FA dance), OR
- Google Maps Places API ($17 per 1000 lookups + a Places API project)

TripAdvisor reviews require:
- Logged-in scraping (rate-limited, anti-bot), OR
- TripAdvisor Content API (paid, requires partnership approval)

Neither lends itself to fully-autonomous remote setup. The drafter +
Action Queue pipeline is already useful with manual review entry —
auto-scraping is the cherry on top, not the foundation.

## Manual review entry

```bash
bash /home_ai/scripts/u39-insert-review.sh
# Prompts for: source, location, rating, reviewer, body, posted_at
# INSERTs into guest_reviews; drafter picks up on next run.
```

Or directly via SQL:

```sql
INSERT INTO guest_reviews (review_id, source, location, rating, reviewer_name, body, posted_at)
VALUES ('uniq-id', 'google', 'malthouse', 4, 'Jane D', 'Lovely lunch...', now());
```

## Full scraper roadmap

1. Pick the easier source first: TripAdvisor's public review pages don't require login. Use Playwright with anti-bot headers (real UA, real referer, random delays 2-5s between requests).
2. Persist a state file: `last_scraped_at` per (source, location). Only fetch reviews newer than that.
3. Run weekly: cron `0 9 * * 1` (Mondays 09:00 — catches weekend reviews).
4. For Google, use the Places API Plus plan (cheaper) — needs Vault entry `secret/google-places`.

## Containerisation

When built, this becomes another service under `services/review-scraper/` with its own Dockerfile based on the existing `homeai-playwright` image. Mount-only access to the host filesystem; talks to homeai-postgres on the ai-internal network.
