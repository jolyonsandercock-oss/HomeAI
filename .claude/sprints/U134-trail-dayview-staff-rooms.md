# U134 — Trail integration · day-view drilldown · staff/rota strip · rooms-this-week

**Prereqs**: U133 shipped (week strip, tides, specials, stayovers, reviews scaffold).

**Realm**: `work`. Trail data + rota + room inventory all sit in pub operational scope.

**Remote vs in-person**: 100% remote. Trail key already in hand; needs Vault stash on first run.

**Why this sprint exists**: U133 polished the daily-view tiles. Now Jo needs (a) compliance signals from Trail in the same place, (b) the ability to use the same view to inspect a *different* day by clicking the week strip — not just today, and (c) finer-grained labour + rooms signal density (rota cost, rooms-left-to-sell, weekly room economics, breakfast/lunch/dinner head count) so the dashboard supersedes daily-reality emails.

## Tracks

### T1 — Trail reports ingest + UI (~90 min)

**Realm**: `work`.

**Build**:
- Stash API key in Vault: `vault kv put secret/trail api_key=<key>` via `scripts/oauth/set-trail-creds.sh` (mirrors `set-xero-creds.sh` / `set-vercel-creds.sh` pattern — reads from stdin, never echoes).
- New tables (V149):
  ```sql
  CREATE TABLE trail_reports (
      id BIGSERIAL PRIMARY KEY,
      trail_report_id TEXT NOT NULL,
      location        TEXT NOT NULL,          -- 'malthouse' | 'cafe' | etc.
      report_name     TEXT NOT NULL,          -- 'Opening Checks', 'Closing Checks'
      report_date     DATE NOT NULL,
      cadence         TEXT NOT NULL,          -- 'daily' | 'weekly'
      score_pct       NUMERIC(5,2),
      tasks_total     INTEGER,
      tasks_completed INTEGER,
      tasks_overdue   INTEGER,
      raw_payload     JSONB,
      ingested_at     TIMESTAMPTZ DEFAULT now(),
      realm           TEXT NOT NULL DEFAULT 'work',
      UNIQUE (trail_report_id, report_date)
  );
  CREATE INDEX idx_trail_reports_date ON trail_reports (report_date DESC);
  CREATE INDEX idx_trail_reports_location_date ON trail_reports (location, report_date DESC);
  ```
- `scripts/u134-trail-poll.py` — fetches today's + yesterday's reports from Trail's API; idempotent upsert; once-per-hour cron.
- API root: `https://api.trailapp.io` (verify in implementation). Key sent as `Authorization: Bearer <key>` or `X-API-Key: <key>` — discover on first call.
- New slugs:
  - `trail_reports_today` (param `date`, default = `CURRENT_DATE`): one row per report with score, completed/total, status.
  - `trail_reports_trend_14d` (param `report_name`): score time-series for sparkline.
- UI: new homepage section "Compliance — Trail" with one tile per report row:
  - Report name (e.g. "Opening Checks · Malthouse")
  - Score % (colour-coded: green ≥ 95, amber 80-95, red < 80)
  - Tasks completed / total
  - Tiny sparkline of last 14 days
  - Click-through to a `/app/compliance` page (out of sprint, leave as placeholder for now)

**Acceptance**:
- After first poll: ≥1 row per active Trail report into `trail_reports`.
- Homepage compliance tile populated with score + trend.
- Re-run is idempotent.

**Open question for Jo**: which Trail locations / report names map to "malthouse" vs "cafe"? Will be answered by the first API listing — I'll use the API's `locations` endpoint to discover, but if Trail uses generic names ("Site 1") I may need a mapping config.

---

### T2 — Click-a-day on strip → day-view drilldown (~120 min)

**Realm**: `work`.

**Build**:
- **State pattern**: dashboard accepts a URL search param `?date=YYYY-MM-DD`. When present, every "today" slug is queried with that date. When absent, behaviour unchanged (= today).
- **Slug refactor** (V150): widen each "today" slug to accept a `date` param defaulting to `CURRENT_DATE`. Affected slugs:
  - `frontend_today_gross`
  - `frontend_accommodation_today`
  - `dashboard_covers_today`
  - `dashboard_special_today`
  - `dashboard_checkins_today`
  - `dashboard_stayovers_today`
  - `dashboard_checkouts_today`
  - `trail_reports_today` (already designed with param in T1)
  - `dashboard_specials_next_7d` — kept as-is (always forward from today; not a "day" slug)
  - `dashboard_labour_yesterday` — kept as-is (rolling-window, doesn't pivot)
  - `dashboard_tides_next_7d` — kept as-is (forward window)
  - `dashboard_week_strip` — kept as-is (always today-forward; the strip itself never pivots)

  Pattern per slug:
  ```sql
  -- Before:
  WHERE checkin_date = CURRENT_DATE
  -- After:
  WHERE checkin_date = COALESCE(:date::date, CURRENT_DATE)
  ```
  Each row gets `param_schema = '{"date": {"type":"string","format":"date","optional":true}}'::jsonb`.

- **Frontend**:
  - `app/page.tsx` becomes a wrapper that reads `useSearchParams()` for `date`. If present and != today, it's the "day-view" mode.
  - Pass `{ date }` into each affected `useSlug<>()` call (the runSlug API route already forwards query string params).
  - Each day-tile in the week strip becomes a `<Link href={'/app?date=<day>'}>` — click navigates to that day's view, including next-7-day strip still anchored on today.
  - **Visual cues when not today**:
    - `<body>` (or page wrapper) gets `bg-amber-50/40` tint (pale orange).
    - TopBar shows the page title with day badge: `Dashboard · WED 27 MAY` in caps.
    - Today's leftmost strip tile gets a green `ring-good` highlight + the label "← Back to today" CTA inside it.
  - **Visual cues when today**: identity behaviour, no tint, no badge.
  - Clicking "Today" tile while in day-view clears the param: `<Link href='/app'>`.

**Acceptance**:
- Click any future day in the strip → page reloads with that day's data in every relevant tile (gross may show 0 if no data exists for future days — graceful).
- URL reflects state: `/app?date=2026-05-22`.
- Header reads "Dashboard · FRI 22 MAY" in caps.
- Pale-orange page tint visible.
- Today's strip tile turns green with "Back to today" — click clears the param.
- Refresh preserves state.

**Open question for Jo**: which past-day depth should be allowed? The strip only goes today + 6 forward, so past days aren't clickable from the strip — but the URL param accepts any date. Want me to add a small `<input type="date">` in the TopBar for arbitrary date selection? (Not in this sprint unless requested.)

---

### T3 — Strip additions: staff on rota (by team), rota cost, rooms-left-to-sell (~75 min)

**Realm**: `work`.

**Build**:
- **Room inventory**: capture total rentable rooms in `static_context`:
  ```sql
  INSERT INTO static_context (key, value) VALUES
    ('rooms.total.malthouse', '{"count": 7}'::jsonb)  -- confirm count with Jo
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
  ```
- New slug `dashboard_week_strip_extras` (V151) — runs alongside `dashboard_week_strip`, returns per day:
  - `staff_kitchen`, `staff_foh`, `staff_accom`, `staff_cafe` — head count per team from `v_workforce_shifts_costed` (or `workforce_shifts`)
  - `rota_cost_total` — sum of `cost_with_oncost` per day
  - `rooms_total`, `rooms_booked`, `rooms_left` — `static_context` ÷ existing rooms CTE
- Frontend: extend each day-tile with three new labelled lines:
  - `Users-icon  <total> on rota` (with hover-or-secondary line: K2 · F3 · A1)
  - `PoundSterling-icon  £rota_cost`
  - `Bed-icon  <booked>/<total>` (already shown — now adds `(<left> left)` suffix in amber when > 0)

**Acceptance**:
- Each day-tile shows the three new lines. Empty/zero days hide gracefully.
- Rota cost numbers match `v_workforce_shifts_costed` totals for that date.
- "Rooms left" reads `static_context.rooms.total.malthouse - booked` and rounds non-negative.

**Open question for Jo**: total room count for Malthouse (7? 8?). Cafe doesn't have rooms — only the pub.

---

### T4 — Rooms section: sold/unsold this week + average stay length (~45 min)

**Realm**: `work`.

**Build**:
- New slug `rooms_week_economics` (V152):
  - `room_nights_sold` for the current ISO week
  - `room_nights_capacity` = rooms_total × 7
  - `pct_occupied`
  - `avg_stay_nights` = AVG(checkout_date - checkin_date) across bookings whose checkin falls inside the week
- New section on homepage between week strip and quick-counts ("Rooms — this week"):
  - 4 KPICards: Nights sold · Nights unsold · % occupied · Avg stay (nights)
  - Subtitle: "Week of YYYY-MM-DD (Monday-anchored)"

**Acceptance**:
- KPI numbers reconcile with strip's per-day rooms_booked summed.
- Avg stay reads as e.g. "2.4 nights".

---

### T5 — Covers breakdown: breakfast · lunch · dinner (~30 min)

**Realm**: `work`.

**Build**:
- Update `dashboard_covers_today` slug (V153) to add a `breakfast_count` column:
  - Breakfast head count = sum of guests staying *previous night* (so this morning's breakfasts). Specifically: `(adults + COALESCE(children, 0))` summed across `accommodation_bookings` where `checkin_date <= CURRENT_DATE - 1 AND checkout_date > CURRENT_DATE - 1` (i.e. they were here last night). Subtract guests who explicitly opted out (if we track that — for now, assume all guests have breakfast).
  - Note: this means on Day 0 (arrival day) a guest isn't counted for breakfast that morning — only from their second morning onward, which matches normal hotel logic.
- Frontend: "Today at a glance" grid grows from 5 to 6 KPICards: Rooms booked · Arrivals · Departures · **Breakfast** · Lunches · Dinners.

**Acceptance**:
- Breakfast count = guests staying last night.
- On a day with 6 stayovers (party_size sum = 12) and no other input: breakfast = 12, lunch + dinner from reservations as before.

---

## Migration order

| # | File | Track |
|---|---|---|
| V149 | `u134_trail_reports` | T1 |
| V150 | `u134_date_param_slugs` | T2 |
| V151 | `u134_week_strip_extras` | T3 |
| V152 | `u134_rooms_week_economics` | T4 |
| V153 | `u134_covers_breakfast` | T5 |

## What this sprint does NOT do

- Does **not** build a `/app/compliance` page for Trail drilldown — the homepage tile + sparkline is enough for v1; the deep page is a U135 follow-up if Jo wants per-report task lists.
- Does **not** make past days (before today) clickable from the strip — the strip is forward-only; date-param accepts any date but the UI doesn't expose past-date navigation in this sprint.
- Does **not** automate posting Trail completion data back — read-only mirror only.
- Does **not** rewrite the labour tile to be date-aware (it's a rolling-window comparison, not a snapshot).

## Anti-regression checks

- U133's `frontend_today_gross` fallback (today → latest available report_date) must still trigger when `?date=` is omitted. The new `:date` plumbing should COALESCE properly so today-mode behaves identically.
- Re-probe of every active slug: still 78+ passing, no new 500s.
- Week strip still renders 7 day-tiles starting today.

## Follow-on sprints

- **U135** — `/app/compliance` deep page: per-Trail-report task list, photo evidence viewer, overdue alerts.
- **U136** — restore Past-day navigation: arrow keys / date picker for arbitrary past-date views.
