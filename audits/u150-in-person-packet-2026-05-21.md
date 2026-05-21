# In-person packet — 2026-05-21

Items needing Jo's physical access. Drives the next in-person session.

## Mortgage statement gaps (high value — VAT + capital tracking)

From `v_mortgage_coverage`:

| loan | account | active | missing quarters | priority |
|---|---|---|---|---|
| 1 | 295905-02 (Principality cross-collateral, Castle Rd + Salutations) | yes | 11 (2020-Q1 to 2026-Q2 scattered) | **highest** — active loan |
| 2 | 967002-01 | yes | 5 (2025-Q2 onward) | high — active loan, recent gaps |
| 3 | 967003-10 | yes | 5 (2025-Q2 onward) | high — active loan, recent gaps |
| 4 | 284512-03 | no | 12 (2019-Q1 to 2023-Q4) | low — retired loan |
| 5 | 289751-04 | no | 12 (same range) | low — retired loan |

**Action**: dig out paper statements for the 21 missing quarters across the 3 active loans. Scan + drop into Paperless or `/home_ai/data/paperless/inbox/`.

## Trail API base URL

`u134-trail-poll.py` tries `api.trailapp.net`, `api.trailapp.io`, `app.trailapp.net/api/v1` — none reachable.

**Action**: confirm correct base from Trail's account settings. Update `DEFAULT_BASES` in the script and re-run.

## Reviews scraper — seed listing URLs

`u133-scrape-reviews.py` exits with "no active listings in review_listings — nothing to scrape".

**Action**: provide URLs for Google Reviews + TripAdvisor for The Olde Malthouse and the Café:
```sql
INSERT INTO review_listings (source, location, listing_url) VALUES
  ('google','malthouse','<url>'),
  ('google','cafe','<url>'),
  ('tripadvisor','malthouse','<url>'),
  ('tripadvisor','cafe','<url>');
```

## Dojo CSV uploads

`dojo_transactions.max(transaction_date)` = 2026-05-14 — 7 days stale.

**Action**: log into Dojo, export Transactions CSV for 2026-05-15 → today, drop into `/home_ai/data/dojo-inbox/` (the `u135-dojo-inbox-sweep.sh` cron will pick it up at 05:30).

## Vault rotation calendar

Per the rotation schedule (memory: `feedback_homeai`), check Vault rotation status:
- Anthropic API key — when last rotated?
- Gmail OAuth client secret — when?
- Telegram bot token — when?

**Action**: confirm rotation interval is being followed; rotate any due.

## V177 service migration sign-off

V177 RLS roles applied + pen-tested 2026-05-21. Pen-test green (trading_role/personal_role isolate cleanly; owner_role bypasses). Consumer mapping doc at `.claude/plans/u147-consumer-mapping.md`.

**Action**: review consumer mapping, then green-light staged service migration (one at a time, watch each).

## Quota hard-mode flip sign-off

7d shadow audit shows zero would-block events at any tier; peak utilization 23.7%. Safe to flip all 4 tiers to hard mode in one go.

**Action**: green-light `UPDATE quota_allocations SET enforce_mode = true;` — single-line flip.
