# U133 — Dashboard polish: week strip, tides, sunset, glyphs, stayovers, reviews scrape

**Prereqs**: U132 shipped (all slugs live). [[U127]] Next.js dashboard at `/app/`.

**Realm**: `work` (all of this is pub/cafe operational data). Tides + sunset are public weather data, treated as `work` because they drive operational decisions (beach footfall).

**Remote vs in-person**: ~100% remote. Only T2 (tide times ingest) needs Jo to email the source list — autonomous once received.

**Why this sprint exists**: The /app/ homepage works but the 7-day strip is too dense to scan, half its glyphs are unclear, and several signals Jo actually uses to plan service (sunset times, tide times, group specials per day, stayovers) are missing or mis-presented. Reviews need a scraper before the U120 nudge flow becomes a closed loop. This is a UX-density-and-data-coverage pass on the daily-driver page — no architecture change.

## Tracks

### T1 — Week strip: today-first, 7 days forward (~30 min)

**Realm**: `work`.

**Current**: `dashboard_week_strip` slug emits 7 days centered on today (`CURRENT_DATE - 3` to `CURRENT_DATE + 3`). Past days clutter the strip; planning value is forward-looking.

**Build**:
- Update `dashboard_week_strip` slug SQL: `generate_series(CURRENT_DATE, CURRENT_DATE + INTERVAL '6 days', INTERVAL '1 day')` — today plus 6 forward days.
- Migration `V143__u133_week_strip_forward.sql`.
- No frontend change needed (the array order naturally puts today first).

**Acceptance**:
- `GET /app/api/slug/dashboard_week_strip` returns 7 rows starting with today's date.
- Homepage strip shows today as the leftmost tile, visually distinct (existing CSS already highlights `dates.day = CURRENT_DATE`).

---

### T2 — Tide times table + weekly scrape from tidetimes.org.uk (~60 min)

**Realm**: `work`. Public data but operationally relevant — beach traffic correlates with low-tide windows for the cafe.

**Build**:
- New table `tide_times` via `V144__u133_tide_times.sql`:
  ```sql
  CREATE TABLE tide_times (
      id BIGSERIAL PRIMARY KEY,
      tide_date DATE NOT NULL,
      high_low TEXT NOT NULL CHECK (high_low IN ('high','low')),
      tide_time TIME NOT NULL,
      height_m NUMERIC(4,2),
      location TEXT NOT NULL DEFAULT 'boscastle',
      source TEXT NOT NULL DEFAULT 'tidetimes.org.uk',
      scraped_at TIMESTAMPTZ DEFAULT now(),
      realm TEXT NOT NULL DEFAULT 'work',
      UNIQUE (location, tide_date, tide_time)
  );
  CREATE INDEX idx_tide_times_date ON tide_times (tide_date);
  ```
- `scripts/u133-scrape-tides.py` — fetch `https://www.tidetimes.org.uk/boscastle-tide-times`, parse the next 7 days of high/low tide rows, idempotent-upsert into `tide_times`. Pure HTTP + BeautifulSoup (no Playwright — the page is static HTML, no JS gate). Respect robots.txt.
- Weekly cron Sunday 06:00 via `crontab.d/u133-tides-weekly`. Catches new week before Jo plans Monday.
- New slug `dashboard_tides_next_7d`: returns next 7 days × all high/low entries for the strip.
- Surface on week strip: tides inline per day — `H 09:14 · L 15:32` (or icons ↑/↓ if compact).

**Acceptance**:
- First run populates ≥7 days × ~4 tide entries per day from boscastle URL.
- Re-running scraper is idempotent (UNIQUE on location+date+time).
- Dashboard strip shows tide row per day; days outside the scrape window render nothing.

---

### T3 — Sunset times visible per day (~10 min)

**Realm**: `work`.

**Current**: `dashboard_week_strip` already returns `sunset` per day (it's there in the SQL — comes from `weather_forecast`). The homepage renders both `<Sunrise>{sunrise}` and `<Sunset>{sunset}` (page.tsx:183-184). Visually they're tiny + same-row → hard to distinguish.

**Build**:
- Promote sunset to its own line within the day-tile, with a clearer glyph.
- Drop sunrise from the small font (it's redundant on a forward-7-day strip — Jo cares about closing-time light for outdoor seating).

**Acceptance**:
- Each day in the strip shows sunset prominently (HH:MM next to a clear sunset glyph).
- Sunrise no longer rendered (de-noise).

---

### T4 — Replace 🛏 7 · L 2 · D 1 cryptic glyphs (~20 min)

**Realm**: `work`.

**Current** (`page.tsx:187-190`): `🛏 7 · L 2 · D 1 · S 0` — bed-emoji-rooms, L=Lunch, D=Dinner, S=Sunday-lunch. Confusing without legend; Sunday-lunch zero is noise.

**Build**:
- Switch to lucide icons + small inline labels:
  - `<Bed size={11}/> 7 rooms`
  - `<UtensilsCrossed size={11}/> 2 lunch · 1 dinner`
  - `<Wine size={11}/> 4 group` (group bookings per day, see T5)
- Drop the Sunday-lunch line entirely — it's already captured under "lunch" and only matters on Sundays (which the day-label already makes obvious).

**Acceptance**:
- Each day-tile in the strip shows three labelled lines: rooms / covers / groups. No bare letters.
- 0-value lines hidden (current behaviour preserved).

---

### T5 — Specials/group bookings per day in the strip (~45 min)

**Realm**: `work`.

**Current**: `dashboard_special_today` only returns *today's* group bookings and stays. The week-strip view doesn't surface group bookings at all — Jo finds out via the special-occasions tile (which only shows today).

**Build**:
- New slug `dashboard_specials_next_7d`: union of restaurant_reservations (party_size ≥ 8) + accommodation_bookings (adults+children ≥ 4 OR group label) across `CURRENT_DATE .. CURRENT_DATE + 6 days`. Returns: `day, kind, label, party_size`.
- Migration `V145__u133_specials_strip.sql`.
- Frontend: per day-tile, render an inline list of group bookings (max 3 visible, "+N more" if overflow). Click-through to /restaurant or /rooms scoped to that date.

**Acceptance**:
- A day with no groups: nothing rendered (no placeholder).
- A day with groups: each renders one short line ("Smith 12 · dinner" or "Hodges 6 · stay").
- Click-through scopes the destination page to that day.

---

### T6 — Stayovers column on check-ins/check-outs (~20 min)

**Realm**: `work`.

**Current**: Homepage shows 2 stacked panels: "Today's check-ins" (uses `dashboard_checkins_today`) and "Today's check-outs" (uses `dashboard_checkouts_today`). The data is there for stayovers — `frontend_accommodation_today.staying` — but the existing surface is the KPI tile, not a guest list.

**Build**:
- New slug `dashboard_stayovers_today`: guests whose `checkin_date < CURRENT_DATE AND checkout_date > CURRENT_DATE` (i.e. staying tonight, neither arriving nor departing). Returns same shape as check-ins/check-outs: guest_name, room, amount, payment_status.
- Migration `V146__u133_stayovers_slug.sql`.
- Frontend: convert the stacked two-panel layout into a 3-column grid (Check-ins | Stayovers | Check-outs), each rendering a guest list of the same shape.

**Acceptance**:
- All three columns render lists, same row format.
- Empty column shows "No arrivals/stayovers/departures today" placeholder.
- Total = arrivals + stayovers + departures matches occupancy on the Rooms KPI.

---

### T7 — DROPPED — email blocker is OAuth, not slug

**Status**: dropped from sprint. The /comms page banner ("Pending Gmail OAuth re-auth — jo/bot/pounana tokens expired") is the real cause; no slug-side work needed. Resolution is operational, not code: Jo runs `scripts/oauth/redo-google-oauth.sh` (interactive, requires browser sign-in). Once re-auth completes, inbound polling resumes and `email_tasks_open` repopulates automatically — the slug + view already work.

**Action item (out-of-sprint)**: run `redo-google-oauth.sh` against accounts `jo`, `bot`, `pounana`. The daily 06:00 `diagnose` cron already exists per DR runbook; once tokens are refreshed, no further code change is needed.

---

### T8 — Reviews scrape: recent + average + click-through (~90 min)

**Realm**: `work`.

**Current**: `guest_reviews` table exists (schema: review_id, source, location, rating, reviewer_name, body, posted_at, scraped_at, status). 0 rows. `/comms` page has a placeholder.

**Scope (revised)**: harvest recent reviews, show them on /comms with average rating, each row linking to the source review page. NO reply drafts, NO nudge integration in this sprint — those stay in U120 and a future U134.

**Build**:
- Add `review_url TEXT` to `guest_reviews` if not present (V147 migration).
- `scripts/u133-scrape-reviews.py` — Playwright scrape (matches Dext/Xero pattern). One source per worker, all idempotent on `(source, review_id)`.
- Sources, in priority order:
  1. **Google Business Profile** — Malthouse + Sandwich Bay café (public Maps listing page is sufficient; no login needed for read).
  2. **TripAdvisor** — both listings.
  3. **Booking.com guest reviews** — public listing page (no login needed; private dashboard is richer but adds an auth dependency).
- Daily cron via `crontab.d/u133-reviews-daily`.
- New slugs:
  - `reviews_recent`: most recent 50 reviews across all sources. Returns: `posted_at, source, location, rating, reviewer_name, body_excerpt, review_url`.
  - `reviews_average_30d`: rolling 30-day average rating per source × location. Returns: `source, location, avg_rating, review_count`.
- `/comms/page.tsx` updates:
  - Replace placeholder with two panels: "Average rating" (one tile per source-location showing the 30d avg + count) and "Recent reviews" (list, newest first).
  - Each row in "Recent reviews" is clickable — `<a href={review.review_url} target="_blank">` to the original page on Google/TripAdvisor/Booking.com.

**Acceptance**:
- After first scrape: ≥10 reviews per source captured into `guest_reviews` with `review_url` populated.
- `/comms` shows the average-rating tiles and the recent-reviews list.
- Clicking a review opens the source page in a new tab.
- Daily cron keeps the data fresh.

**Open question for Jo**: confirm Google Maps + TripAdvisor + Booking.com public-page scrape is OK (no login = no T&C friction, no cred storage, but rate-limited). If you want richer data (private review-management dashboard for Google/Booking.com), that adds an OAuth dependency — defer to U134.

---

### T9 — Colour-code gross + labour tile reshape + clickable to /staff (~30 min)

**Realm**: `work`.

**Current**:
- "Gross today" tile (page.tsx:107-124): big number, no colour signal vs target/budget.
- Labour tile (the right tile in ROW 1): shows pub + cafe labour-vs-sales ratios as numbers — but without "labour" / "sales" labels. Not clickable.

**Build**:
- Gross tile: apply traffic-light colour to the £-figure based on a daily target (params: green ≥ £2000, amber £1500-2000, red < £1500 for the pub; café threshold half of pub, configurable in `static_context`). Tile already lives inside a `<Link href="/sales">` so click-through is fine.
- Labour tile:
  - Wrap entire tile in `<Link href="/staff">` (mirrors the Gross tile pattern).
  - Add explicit "Labour" and "Sales" labels above each number column.
  - Apply the same traffic-light to the labour/sales **percentage** (green < 30%, amber 30-35%, red > 35%).
  - Add "→ Click for Staff detail" hover hint.

**Acceptance**:
- Gross figure rendered with `text-green-500` / `text-amber-500` / `text-red-500` per threshold.
- Labour tile click navigates to /staff.
- Each labour percentage column has its label (Labour / Sales) above the figure.
- Percentages colour-coded.

---

## What this sprint does NOT do

- Does **not** redesign the overall information architecture of /app/ — only polishes the existing tiles.
- Does **not** build a full review-response automation. T8 captures reviews into the DB; the U120 nudge already handles drafting; closing the loop (auto-post replies) is a future sprint.
- Does **not** change the desktop UI (/desktop on build-dashboard) — those edits live in the U85 codebase and have their own velocity.
- Does **not** add new charting libraries — sticks with the existing Tailwind + lucide stack.

## Migration order

| # | File | Track |
|---|---|---|
| V143 | `u133_week_strip_forward` | T1 |
| V144 | `u133_tide_times` | T2 |
| V145 | `u133_specials_strip` | T5 |
| V146 | `u133_stayovers_slug` | T6 |
| V147 | `u133_reviews_url_and_slugs` | T8 (adds `review_url` col + reviews_recent + reviews_average_30d slugs) |

T7 dropped — OAuth re-auth resolves it without code changes.

## Anti-regression checks

- Before merging: re-run the U132 slug audit (`docker exec homeai-postgres psql -tAc "SELECT slug FROM query_whitelist WHERE active=true"` × probe each). Expect: same 78 passing → now 78 + 3 new (week-strip-forward unchanged-count, specials_next_7d, stayovers_today, reviews_recent_unanswered, dashboard_tide_today_to_week).
- After deploy: hard-refresh `/app/` and confirm each section: 7-day strip today-first, sunset visible, glyphs labelled, group-bookings inline, 3-column check-ins/stayovers/check-outs, gross + labour colour-coded, labour clicks through.

## Follow-on sprints

- **U134** — review-response loop: once T8 is harvesting, draft replies via Sonnet + post-via-OAuth (Google Business / Booking.com management dashboards), close the loop the U120 nudge already started.
- **U135** — full /comms IA pass: once Gmail re-auth lands and `email_tasks_open` is repopulating, /comms needs its own layout review (it's currently a placeholder-heavy page).

## Out-of-sprint action items

- **OAuth re-auth (Gmail jo/bot/pounana)**: run `scripts/oauth/redo-google-oauth.sh` interactively. Unblocks /comms email panel and inbound polling. Not a code change — operational task only. (Daily 06:00 `diagnose` cron is already in place per DR runbook.)
