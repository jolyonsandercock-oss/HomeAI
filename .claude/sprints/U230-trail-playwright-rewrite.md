# U230 — Trail Playwright rewrite (closes U156)

**Realm:** work (pub compliance / food hygiene). Trail is the food-hygiene tracker for The Olde Malthouse pub kitchen.

**Trigger:** `u134-trail-poll.py` cannot work — Trail is not a REST API. Per memory `feedback-trail-oidc-not-api`: Trail = Access Group SSO (OAuth2/OIDC via `identity.accessacloud.com`). The poll script attempts API auth that doesn't exist. Original U156 sprint plan was filed but never closed; `trail_reports` table currently 43h stale (warn) and growing.

**Status:** queued. (Sprint plan U156 exists in `/home_ai/.claude/sprints/U156-trail-playwright-scraper.md` — this sprint supersedes it with the post-recovery context.)

**Why it matters:** Trail produces the food hygiene compliance reports the pub needs for FSA inspections. Missing them risks a regulatory finding. The current dashboard's "trail_reports" tile silently shows stale data — no alert fires (per [[feedback-alerting-circular-dep]] resolved in U228).

---

## T1 — Audit U156 plan + current state

- [ ] Read existing `/home_ai/.claude/sprints/U156-trail-playwright-scraper.md`.
- [ ] Read `/home_ai/scripts/u134-trail-poll.py` (or equivalent) — capture what's currently scheduled.
- [ ] Confirm `secret/trail` in vault has `username`, `password`, and `report_type` keys (per memory `feedback-trail-oidc-not-api`).
- [ ] Confirm what fields `trail_reports` expects (columns + uniqueness).

## T2 — Build the Playwright scraper

Reuse `homeai-playwright` container (already healthy per 2026-05-28 verification). Add a new endpoint `/ingest/trail`.

- [ ] Add a `trail_login()` helper:
  1. POST to `identity.accessacloud.com` OIDC login (form-based, may require initial OIDC initiation flow handshake)
  2. Follow redirect chain
  3. Land on the Trail dashboard logged in
- [ ] Add a `trail_fetch_reports(date_from, date_to)` helper that navigates to the reports list, scrapes the table, returns rows as JSON.
- [ ] Wire `/ingest/trail` POST endpoint that takes a date range and returns scraped rows.
- [ ] Add cookie persistence (`storage_state.json` per memory pattern — Trail will refuse repeated logins if too frequent).

## T3 — Schedule + ingest

- [ ] New cron `0 6 * * * /home_ai/scripts/u230-trail-poll.sh >> /home_ai/logs/u230-trail.log 2>&1` (daily 06:00 BST).
- [ ] `u230-trail-poll.sh`: hits `http://homeai-playwright:<port>/ingest/trail`, accepts JSON, INSERTs into `trail_reports` with `ON CONFLICT (date, report_type) DO UPDATE SET …`.
- [ ] Decommission `u134-trail-poll.py` cron (remove + archive).

## T4 — Backfill recent reports

- [ ] Run the scraper for the last 14 days to fill the gap since the broken poll started failing.
- [ ] Verify `trail_reports` shows fresh data.

## T5 — Verify + alert wiring

- [ ] `data_source_freshness` slug shows `trail_reports` status `ok`.
- [ ] Alert rule `TrailReportsStale` fires if no new row in 48h → routes through the U228 alert-sink-notify chain.

---

## Deferred / out of scope

- **OIDC token caching across runs** — Trail's session lifetime is short; per-run login is fine while we run daily. Revisit if frequency increases.
- **Multi-property Trail accounts** — only the pub uses Trail today; cafe / accommodation are not on the platform.
- **2FA on the Trail account** — if/when Trail enables enforced 2FA, this script breaks and needs a TOTP-aware path. Not in scope until that day.
- **Replacement of Trail with something we host** — that's a much bigger food-safety SaaS replacement question; out of scope.
