# Review owner-APIs + TouchOffice API migration — implementation plan

> Two independent "stop scraping, use the real API" migrations, planned together
> because they share the pattern: authenticate once, call a JSON endpoint, parse,
> upsert. Each phase is shippable on its own.

**Goal:** replace blocked/fragile browser scrapes with authenticated data APIs —
guest reviews from the platforms Jo owns, and TouchOffice EPoS revenue from the
JSON endpoints under its own dashboard.

**Investigation findings (2026-07-10, evidence-based):**
- **Caterbook API cannot see TouchOffice.** Caterbook is an accommodation PMS
  (endpoints: GetArrivals, GetBookingDetails — rooms only). It is a different
  vendor from ICRTouch/TouchOffice; there is no EPoS data underneath it. Dead end.
- **Tanda/Workforce API carries no sales data.** Live read-only probe:
  `/api/v2/wage_comparisons` returns `[]` (no POS feed configured);
  `/api/v2/sales`, `/roster/sales`, `/platform/sales` all 404. Dead end.
- **TouchOffice Web has a JSON API under its own dashboard — WIN.** Live network
  capture of the widget scrape shows the three revenue widgets are backed by:
  `GET /apps/ajaxloader?call=fixedtotal` (FIXED TOTALS = head_office consolidated
  revenue), `call=departmentSalesTotal`, `call=PLUSales`, plus `clerksBreakdown`
  and `last100`. All return `application/json`, session-cookie auth, date/site
  scoping carried in session (set by the existing filter POST to `/`). Same class
  of discovery as the Caterbook reverse-API. This replaces the DOM-table walk.

## Global Constraints
- All new external creds live in Vault under `secret/<service>`; never in code/env.
- Every sync is READ-ONLY against the external API, idempotent (UPSERT on external
  id), and logs each call (status, ms, rows) to an existing `*_sync_log` table.
- Reviews land in `guest_reviews` using the existing dedup id convention
  (`<src>-web-` + md5). Cross-check both dedup layers (id + month/fragment) that
  `u297-review-sweep-ingest.py` already implements — reuse that ingest, don't fork it.
- Realm/entity: reviews are `entity_id=1, realm='work'`; TouchOffice revenue keeps
  its current `head_office` truth model (`feedback_touchoffice_headoffice_revenue`).
- Owner-portal setup steps (claiming a listing, generating an API key) are JO
  actions — the plan flags each one explicitly; do not attempt to automate a login.

---

## Phase A — Google reviews via Google Business Profile API (highest value first)

**Why first:** the current Google scraper is a dead stub (points at a Google
Travel *search* page with no review content); Google is the biggest gap; and the
API is clean, free, and Jo owns the listing.

### Task A1: Enable the API + OAuth consent (JO action, then wiring)
**Files:** none yet — this is the credential-acquisition gate.
- [ ] **Jo:** in Google Cloud Console, enable **Google Business Profile API** on a
      project, create an OAuth client (Web), add `jolyboxbot@gmail.com` as a test
      user; scope `https://www.googleapis.com/auth/business.manage`.
- [ ] **Jo:** one-time consent so we hold a refresh token for the account that
      manages the Malthouse listing.
- [ ] Store `{client_id, client_secret, refresh_token}` in Vault `secret/gbp`.
- [ ] **Verify:** `POST oauth2.googleapis.com/token` (refresh grant) returns an
      access token; `GET mybusinessaccountmanagement.googleapis.com/v1/accounts`
      returns the account. Expected: 200 + one account.

### Task A2: Resolve account + location ids
**Files:** Create `scripts/u310-gbp-reviews.py` (skeleton + resolver only).
- [ ] `GET /v1/accounts` → account name; `GET /v1/accounts/{acct}/locations` →
      the Malthouse location `name`. Cache both in `secret/gbp` (write-back) so
      later runs skip discovery.
- [ ] **Verify:** printed location name matches "The Olde Malthouse". Run: manual.

### Task A3: Pull reviews + upsert
**Files:** finish `scripts/u310-gbp-reviews.py`; register cron in
`scripts/gen-canonical-crontab.py` NAME_MAP (`gbp_reviews`).
- [ ] `GET .../locations/{loc}/reviews` (paginate `nextPageToken`). Map star enum
      (ONE..FIVE → 1..5), reviewer displayName, comment, createTime.
- [ ] Upsert into `guest_reviews` with `review_id = 'g-web-' + md5(reviewer|comment[:40])`
      via the existing INSERT…SELECT…WHERE NOT EXISTS idiom (no unique constraint
      on review_id). `source='google'`, `scale=5`.
- [ ] Log to a `*_sync_log`; print `OPS_ROWS=<inserted>` for the ops-run wrapper.
- [ ] Cron `0 7 * * *` under `ops-run.sh gbp_reviews`.
- [ ] **Verify:** first run inserts the current Google review set; second run
      inserts 0 (idempotent). Cross-check count vs the live listing.

---

## Phase B — Booking.com reviews via the partner Reviews API

**Why:** Jo is already a Booking.com partner (takes bookings through them), so the
partner API is available; the email feed silently died on 2026-06-01 and this is
where the recent bad reviews landed.

### Task B1: Partner API access (JO action)
- [ ] **Jo:** in the Booking.com **Extranet → Account → API**, confirm whether the
      Connectivity/Reviews API is enabled for the property (or request it). Some
      properties reach reviews via a Connectivity Provider rather than direct — if
      direct access isn't offered, note the provider and STOP for a decision.
- [ ] Store `{property_id, api_key/username+password}` in Vault `secret/booking`.
- [ ] **Verify:** authenticated GET of the property returns 200.

### Task B2: Reviews sync
**Files:** Create `scripts/u311-booking-reviews.py`; NAME_MAP `booking_reviews`.
- [ ] Pull the property's guest reviews (score /10, positive + negative text, date,
      reviewer country/name where present). Preserve BOTH liked/disliked halves in
      `body` (the ingest and email format expect the full text).
- [ ] Upsert with `review_id='bk-web-'+md5(...)`, `source='booking_com'`, `scale=10`.
- [ ] Cron `0 7 * * *`. Print OPS_ROWS.
- [ ] **Verify:** the 14 reviews the dead email feed missed (2026-06 onward) appear;
      re-run inserts 0.

---

## Phase C — Expedia reviews via Partner Central

### Task C1: Access (JO action)
- [ ] **Jo:** Expedia **Partner Central → Guest Reviews**; check for API access
      (Expedia's Rapid/Partner APIs, or a reviews export). If only a CSV/manual
      export exists, fall back to a monthly manual export dropped into
      `data/review-sweep/` and parsed by the existing ingest. Record which.
- [ ] Store creds in Vault `secret/expedia` if an API exists.

### Task C2: Sync or export-ingest
**Files:** `scripts/u312-expedia-reviews.py` OR extend `u297` to read an export.
- [ ] Upsert `review_id='exp-web-'+md5(...)`, `source='expedia'`, `scale=10`.
- [ ] **Verify:** current Expedia reviews present; idempotent re-run.

---

## Phase D — TripAdvisor Content API (ratings + recent reviews)

**Why:** the site itself is DataDome-walled; the Content API is the sanctioned
route. Caveat: the free tier returns ratings + a small number of recent reviews,
not the full history — so this augments the email feed, doesn't replace it.

### Task D1: API key (JO action)
- [ ] **Jo:** register for a TripAdvisor **Content API** key; claim/verify the two
      Malthouse listings (restaurant d1536289, hotel d677960) in the management
      centre. Store `{api_key}` in Vault `secret/tripadvisor`.

### Task D2: Sync
**Files:** `scripts/u313-tripadvisor-reviews.py`; NAME_MAP `tripadvisor_api`.
- [ ] `GET /api/partner/2.0/location/{id}/reviews?key=...` for both location ids.
- [ ] Upsert `review_id='ta-web-'+md5(...)`, `source='tripadvisor'`, `scale=5`.
- [ ] **Verify:** the four sub-5★ reviews the email feed hid (email delivers only
      5★) now appear; idempotent.

### Task D3: Retire the blocked scrape path
- [ ] Once A–D are live and proven for ≥3 days, disable the DataDome-blocked cloud
      review-sweep routine (or keep it as a Booking-only backstop if B stalls on the
      provider question). Update `MEMORY.md` and remove the dead `u133` review stubs.

---

## Phase E — TouchOffice: DOM-scrape → JSON API (the bonus win)

**Why:** the browser scrape is the single slowest, most fragile job we run (5-min
timeouts, lazy-load scrolls, per-widget table walks, transient DNS retries). The
same data is one authenticated JSON GET away.

### Task E1: Confirm the JSON payload shape (spike, read-only)
**Files:** throwaway probe.
- [ ] Reuse the existing login (Vault `secret/touchoffice`), set site + POST the
      date filter to `/` exactly as `touchoffice.py` does today, then
      `GET /apps/ajaxloader?call=fixedtotal` (and `departmentSalesTotal`, `PLUSales`)
      with the session cookie. Capture the JSON structure for head_office/malthouse/
      sandwich for one known date.
- [ ] **Verify:** the JSON figures reconcile TO THE PENNY against a recent
      `touchoffice_scrapes` row for the same date (the head_office FIXED TOTALS is
      the reconciled revenue truth — do NOT ship if it doesn't match).

### Task E2: New API-based ingest behind a flag
**Files:** add `scrape_touchoffice_api()` to the playwright service `main.py`
alongside the browser path; flag `TOUCHOFFICE_MODE=api|browser` (default browser).
- [ ] Log in for a session cookie (still needs the login form — no clean JWT like
      Caterbook), POST the date/site filter, GET the three ajaxloader calls, parse
      JSON into the same `{widgets:{...}}` shape the ingest already consumes.
- [ ] Keep the browser path intact as the fallback.
- [ ] **Verify:** run both modes for the same date; assert identical rows written
      to `touchoffice_scrapes`. Backfill 5 historical dates both ways, diff = 0.

### Task E3: Cut over
- [ ] Flip `TOUCHOFFICE_MODE=api` in the daily/realtime crons after a week of
      shadow agreement; keep the browser fallback wired for a month, then revisit.
- [ ] Update `feedback_touchoffice_headoffice_revenue` memory with the API route.
- [ ] **Guard:** if a future TouchOffice update changes the ajaxloader contract,
      the reconcile assertion in the ingest must fail loudly (not silently write
      zeros) — mirror the existing self-heal.

---

## Sequencing & effort
- **A (Google) and E (TouchOffice)** are the two highest-value, lowest-friction
  wins — start there. A needs one Jo console step; E needs zero Jo steps (creds
  already in Vault) and only a reconcile spike to de-risk.
- **B (Booking)** is high value but gated on the partner/provider question — kick
  off the Jo action early so the answer is back by the time A/E ship.
- **C, D** augment rather than replace; do after A/B/E.
- Each phase: ~1 script + 1 cron line + Vault secret. The reused `guest_reviews`
  ingest and `ops-run` wrapper mean no new infrastructure.
