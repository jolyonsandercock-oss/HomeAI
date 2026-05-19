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

### T2 — Tide times table + ingest (~60 min, blocked on Jo's email)

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
      location TEXT NOT NULL DEFAULT 'sandwich_bay',
      source TEXT NOT NULL,        -- 'jo_email' | 'admiralty_api' | etc.
      ingested_at TIMESTAMPTZ DEFAULT now(),
      realm TEXT NOT NULL DEFAULT 'work',
      UNIQUE (location, tide_date, tide_time)
  );
  CREATE INDEX idx_tide_times_date ON tide_times (tide_date);
  ```
- `scripts/u133-parse-tide-email.py` — accept the email Jo forwards (subject pattern TBD per Jo), parse the tide table, idempotent-upsert into `tide_times`.
- New slug `dashboard_tide_today_to_week`: returns next 7 days × high/low for the strip.
- Surface on week strip: 2 small icons per day (↑ for high, ↓ for low) with HH:MM.

**Acceptance**:
- After Jo emails one month of tides: `tide_times` populated for that month, dashboard strip shows the next 7 days' high+low.
- Re-running the parser is idempotent.
- If no tide data for a date: strip cell renders nothing in that row (graceful degrade), not "—" clutter.

**Open question for Jo**: which email account + subject pattern do tides arrive on? `jo@` with subject "tides"? A specific sender like `info@tide-times.co.uk`? Same parser hook either way; just need the filter.

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

### T7 — Email slug audit + fix (~30 min, scoped TBD)

**Realm**: `work`.

**Current**: There's `email_tasks_open` slug → `SELECT * FROM v_email_tasks_open LIMIT 100`. The `/comms` page has a SandboxWrapper placeholder hint saying email integration is queued.

**Build** (assumed scope — confirm with Jo):
- Audit what `v_email_tasks_open` returns vs what `/comms/page.tsx` should display.
- If view shape ≠ UI expectation: rewrite the slug to project the right columns (`from`, `subject`, `received_at`, `lane`, `priority`, `link_to_thread`).
- Surface the slug in `/comms/page.tsx` as a real (not placeholder) tile: "Open email tasks · click row → Gmail thread".

**Acceptance**:
- `/comms` page shows the live open-email-tasks list with deep-links to Gmail message IDs.
- Empty state handled.

**Open question for Jo**: what specifically is broken about the email slug? Is it that the data returned is wrong, or that nothing surfaces it on /comms? (T7 above assumes the latter.)

---

### T8 — Reviews scrape (~120 min, biggest track)

**Realm**: `work`.

**Current**: `guest_reviews` table exists (schema: review_id, source, location, rating, reviewer_name, body, posted_at, scraped_at, status). 0 rows. `/comms` page has a placeholder. The U120 review-nudge flow drafts WA messages but has no review data to react to.

**Build**:
- `scripts/u133-scrape-reviews.py` — Playwright (uses the existing Dext/Xero scraping pattern). One-time stored creds per source in Vault (`secret/reviews/{google,tripadvisor,booking_com}`).
- Sources, in priority order:
  1. **Google Business Profile** — Malthouse + Sandwich café listings (`/business.google.com` or the public maps page if scrape-only).
  2. **TripAdvisor** — both listings.
  3. **Booking.com guest reviews** — extension of existing Caterbook scraping context (different login though).
- Daily cron via `crontab.d/u133-reviews-daily`.
- Idempotent on `(source, review_id)`.
- New slug `reviews_recent_unanswered`: most recent 50 reviews where `status = 'new'`, joined to the WA-draft from U120 if exists.

**Acceptance**:
- After first scrape: `guest_reviews` populated with ≥10 reviews per source.
- `/comms` reviews panel surfaces the list with rating + body excerpt + "draft reply" button.
- Daily cron keeps it fresh.

**Open question for Jo**:
1. Which sources are in scope for v1? Recommend Google + TripAdvisor + Booking.com (matches existing guest-channel coverage).
2. Confirm creds available for each — Google Business needs OAuth or login session; TripAdvisor needs account; Booking.com piggybacks Caterbook auth.
3. Where do reply DRAFTS go — back into the existing `review_drafts` table from U120, or somewhere new?

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

V147+ reserved for T7/T8 slug definitions once their shape is locked.

## Anti-regression checks

- Before merging: re-run the U132 slug audit (`docker exec homeai-postgres psql -tAc "SELECT slug FROM query_whitelist WHERE active=true"` × probe each). Expect: same 78 passing → now 78 + 3 new (week-strip-forward unchanged-count, specials_next_7d, stayovers_today, reviews_recent_unanswered, dashboard_tide_today_to_week).
- After deploy: hard-refresh `/app/` and confirm each section: 7-day strip today-first, sunset visible, glyphs labelled, group-bookings inline, 3-column check-ins/stayovers/check-outs, gross + labour colour-coded, labour clicks through.

## Follow-on sprints

- **U134** — reply-posting automation: once T8 is harvesting, close the loop with WhatsApp / email replies to reviews.
- **U135** — full /comms IA pass: email is currently a placeholder; once T7 + T8 land, /comms needs its own layout review.
