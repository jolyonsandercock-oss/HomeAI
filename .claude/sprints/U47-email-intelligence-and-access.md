# U47 — UX repairs + email intelligence + access split

**Prereqs**: U46 shipped (TouchOffice integrity + email_tasks scaffold + weather + GP buckets).

**Remote-doable**: 100% except Track 8 (Caddy basic-auth) which can be scripted but Jo verifies in the browser.

This sprint absorbs the punchlist from Jo's 13/5 review of the U45 pages:
invoice UX, GP boxes, pub live ops, weather backfill, workforce coverage,
date-picker presets, sales-per-staff ranking, and the email-classifier
review queue.

## Tracks

### Track 1 — Invoice page UX repairs (~1.5 hr)

Issues observed:
- ✎ pencil exists at `invoices.html:227` but is invisible/hard to spot — needs a clearer affordance + tooltip + maybe a column header note.
- Site (pub/café) switcher returns 0 for café because `vendor_invoice_inbox` has no `site` column and the café-stock vendor list is empty (V42's `vendor_category_canonical()` would map café vendors to `cafe_stock` → bucket `cafe`, but Jo hasn't supplied café vendor names yet — café account number is MAL125 only).
- No conversational input on the invoice detail panel for ongoing classification feedback.

**V55 — `vendor_invoice_inbox.site`** generated column:
```sql
ALTER TABLE vendor_invoice_inbox
  ADD COLUMN site TEXT GENERATED ALWAYS AS (
    CASE
      WHEN account_canonical IN ('mal125','sandwich','cafe') THEN 'cafe'
      WHEN account_canonical IN ('malthouse','pub','inn')    THEN 'pub'
      ELSE 'shared'
    END
  ) STORED;
CREATE INDEX idx_vii_site ON vendor_invoice_inbox(site);
```
+ Backfill `account_canonical` from existing `account` / `vendor_name` / supplier match.
+ Add a `site` filter clause to `/api/invoice/queue`.

**UI repairs in `invoices.html`**:
- Make ✎ a proper styled button (`btn-icon`) instead of bare emoji — `bg-slate-700/60 hover:bg-amber-600 rounded px-1.5 py-0.5`. Add `title="Edit / give feedback to AI"`.
- Add a "💬 Feedback" column-header tooltip explaining the loop.
- In the detail modal (`openFeedback`), add a **conversational textarea**:
  > "What would you like the AI to learn from this invoice? e.g. 'always treat
  > this supplier as cafe_stock', 'this is a statement, not an invoice',
  > 'split GP between drink and food 70/30 for this vendor'."
- Free-text → posts to `/api/invoice/{id}/feedback` (already exists from U44).
- Sonnet feedback-applier (`u44-feedback-applier.sh`, cron 21:30) already processes these overnight.

**Acceptance**:
- Café filter returns invoices once a few café vendors are tagged.
- Pencil is clearly visible (review with Jo).
- Conversational feedback box accepts free text and a confirmation toast appears.

### Track 2 — GP box fix: show £ + correct the maths (~1 hr)

Diagnosis: `gp_window()` is mathematically correct, but two issues distort the
displayed GP%:
1. **Café GP always 100%** because no invoice has `vendor_category_bucket = 'cafe'`. Bucket exists in V51 but no vendor maps to `cafe_stock` canonical (Jo's MAL125 + future café vendors not yet tagged).
2. **Short windows look unrealistically high** because invoices arrive lumpily (weekly/monthly) while sales arrive daily — an 8-day window can show £6.6k of wet sales with only £857 of wet cost because that vendor invoices fortnightly.

**Fix**:
- **Always use a 30-day rolling GP** in the dashboard tile (smooths the lumpiness). Add `gp_window_smoothed(d_from, d_to, smoothing_days INT DEFAULT 30)` that accrues invoice cost across delivery_date ± smoothing window proportionally.
- **Show £ alongside %** in each tile:
  - Drink — £rev · £cost · GP%
  - Food  — £rev · £cost · GP%
  - Café  — £rev · £cost · GP% (greyed if cost=0)
  - Overall — £rev · £cost · GP%
- **Stale-data warning** if the window has < N% of the expected invoice count for its length (heuristic: avg invoices/day × window_days × 0.4 floor). Renders the box amber with "low-cost-coverage — figure may be flattering".

**Acceptance**:
- Café tile shows 'no cost data yet' until at least 1 café-bucket invoice is ingested.
- Drink/food/overall tiles each show three numbers: revenue, cost, GP%.
- 8-day window with sparse cost coverage shows amber with the warning.
- 30-day rolling GP on the dashboard is < 95% (sanity check — current 30d shows 87.8% which is healthy).

### Track 3 — Pub live-ops tiles wired to real data (~1 hr)

Jo: "pub live ops not showing any real data".

Audit `/pub` snapshot endpoint (`/api/pub/snapshot`):
- Arrivals today: should come from `caterbook_bookings` where `check_in_date = CURRENT_DATE`.
- Departures tomorrow: same, `check_out_date = CURRENT_DATE + 1`.
- Today's KPI strip: covers, drink sales, food sales, accom revenue.
- This-week calendar: confirmed bookings per day.
- Channel mix: `caterbook_bookings.source` aggregated 14d window.

Likely failure modes:
- View `caterbook_bookings` may not include the current week.
- Channel `source` field may be NULL for recent rows.
- Day-of-week mapping may be off (UTC vs Europe/London).

Need to:
1. Verify each tile against its underlying SQL.
2. Fix any view/JOIN gap.
3. Add an end-to-end test (`tests/test_pub_snapshot.py`) that asserts each tile is non-empty when fixture data exists.

**Acceptance**: `/pub` shows the live numbers Jo can cross-reference against Caterbook.

### Track 4 — Weather backfill (last 400 days) (~30 min)

Jo: "fill in real weather data for last 400 days so we can build queries and search detailed trends".

Currently `weather_daily` has 30d backfilled. Extend to 400d using Open-Meteo's
archive endpoint (free, no auth, supports ranges).

Add `u47-weather-backfill.sh`:
- Pulls Open-Meteo archive from `today-400d` to `today-1d` in one call (single API hit; the archive endpoint returns the entire range at once).
- Idempotent `ON CONFLICT DO UPDATE`.
- One-shot script, not cron'd.

**Acceptance**:
- `SELECT COUNT(*) FROM weather_daily` ≥ 395 (allows for any API gap).
- Spot-check `2025-12-25` and `2025-08-15` for plausibility.
- New view `v_weather_seasonality` (year-prior comparison) becomes useful.

### Track 5 — Workforce page fixes (~1.5 hr)

Issues:
- Today's roster not displaying the team.
- No forecast (rota from Tanda schedule) vs actual (Tanda timesheet) cost diff.
- Top staff table missing shift cost (only shows hours).
- Date picker lacks preset buttons.

**Backend**:
- `/api/workforce/rota_today` — already exists; investigate why empty. Likely
  query window or `entity_id` filter. Add fixture-based test.
- `/api/workforce/forecast_vs_actual?days=N` — already exists; verify the JOIN
  matches `workforce_shifts` (forecast) vs `workforce_timesheets` (actual).
- New `/api/workforce/leaderboard?date_from=X&date_to=Y` returning per-staff:
  hours, shift_cost_actual, attributable_sales, sales_per_hour.

**Sales-per-staff attribution** (this is Track 6 — pulled out separately).

**UI** (`workforce.html`):
- Top "Today's rota" table: name · role · start · end · hours · **£cost (NEW)** · variance-vs-rota.
- Date picker: Yesterday | This week | Last week | Last month | (existing custom range).
- Top staff table: add `shift_cost` and `sales_per_hour` columns.

**Acceptance**:
- Today's rota shows the actual people on shift now (cross-checked vs Tanda).
- Forecast-vs-actual variance is visible (£ over/under) per day for last 7d.
- Date-picker preset buttons set both fields and trigger a refresh.

### Track 6 — Sales-per-staff attribution (~1.5 hr)

Jo: "if Tom is cooking, how much food has been sold on his shifts; if Ben is FoH,
how much drink served; if Tanya is in café, how much café sales".

Requires a department-aware shift-window join:
- `workforce_timesheets` row → (staff_id, dept_id, start_at, end_at, site).
- TouchOffice sales row → (site, ts, dept_canonical, value).
- Caterbook (accom): separate (no per-staff attribution; ignore for this view).

**V56 — `v_staff_sales_window`** materialised view (refreshed nightly):
```sql
SELECT
  t.staff_id,
  t.dept_canonical,                          -- 'kitchen','bar','front_of_house','cafe','accom'
  t.shift_date,
  t.hours_worked,
  t.actual_cost,
  COALESCE(SUM(s.value) FILTER (
    WHERE s.dept_canonical = (
      CASE t.dept_canonical
        WHEN 'kitchen'        THEN 'food'
        WHEN 'bar'            THEN 'drink'
        WHEN 'front_of_house' THEN 'drink+food'
        WHEN 'cafe'           THEN 'cafe'
      END
    )
    AND s.ts BETWEEN t.start_at AND t.end_at
  ), 0) AS attributable_sales
FROM workforce_timesheets t
LEFT JOIN touchoffice_department_sales s ON s.site = t.site
GROUP BY 1,2,3,4,5;
```

Department mapping needs:
- Tanda dept_canonical → TouchOffice dept_canonical translation table (5 rows).
- Already partly done in V42's vendor mapping pattern.

**Endpoint** `/api/workforce/sales_per_hour?date_from=X&date_to=Y` returns:
```
[{staff_id, name, role, hours, shift_cost, attributable_sales,
  sales_per_hour, rank_within_dept}]
```

**UI**: New table on `/workforce`, "Sales per productive hour" leaderboard.
Sortable. Top 5 highlighted gold.

**Caveats**:
- FoH staff get joint drink+food attribution which double-counts if both bar
  and FoH are on simultaneously — display "(shared)" badge.
- Quiet shifts (rev=0) divide-by-zero → return NULL, show "—" not £0.

**Acceptance**:
- Tom (kitchen, made-up shift) → food sales for his window.
- Ben (FoH) → drink+food for his window (with the shared badge).
- Leaderboard ranks staff by sales-per-hour for any custom date window.

### Track 7 — Email classifier review queue (high-doubt surfacing) (~1.5 hr)

Jo: "the email classifier should surface high doubt emails for discussion.
pasting in isn't good ux, revise this".

Two-part fix:

**7a. Bot-responder confidence threshold**:
- Existing `bot-responder` already emits a `confidence_score` (0–1) per classification.
- Add a `confidence_low_queue` view: `WHERE confidence_score < 0.7 AND created_at > now() - INTERVAL '7 days'`.
- Mission Control card "AI uncertain — needs your eye" listing those rows with Accept/Override buttons.
- One-click "Override → reclassify as X" feeds back to `bot_feedback` table (NEW V57) which the dreaming workflow uses to refine prompts/heuristics.

**7b. Better classification UX (no copy-paste)**:
Instead of "paste an email in", the workflow becomes:
1. Inbound email is parsed by Haiku → classification + confidence.
2. If confidence < 0.7 OR Jo flagged the row in `bot_feedback` → it surfaces.
3. Jo clicks the row. The full email source viewer opens inline (`/viewer/email/{account}/{message_id}` — already exists).
4. Below the source: dropdown (correct category), radio (priority), free-text ("AI should also learn that …").
5. Submit → INSERT into `bot_feedback` → Sonnet overnight pass updates classifier prompts.

**V57 — `bot_feedback`**:
```sql
CREATE TABLE bot_feedback (
  id              BIGSERIAL PRIMARY KEY,
  email_id        BIGINT REFERENCES emails(id),
  original_class  TEXT,
  corrected_class TEXT,
  original_conf   NUMERIC(3,2),
  notes           TEXT,
  applied         BOOLEAN DEFAULT false,
  created_at      TIMESTAMPTZ DEFAULT now(),
  applied_at      TIMESTAMPTZ
);
```

**Acceptance**:
- Mission Control "AI uncertain" card lists at least 1 row from a real low-conf classification (we have plenty under conf 0.7).
- Clicking opens the email source viewer + correction form.
- After submit, row disappears from the queue and shows in `bot_feedback`.
- Sonnet overnight pass (extends `u44-feedback-applier.sh`) ingests it.

### Track 8 — Dashboard password split: staff vs family (~2 hr)

(Unchanged from the original U47 plan — see prior content below.)

Caddy basic-auth on `/staff/*` and `/family/*`:
- Staff sees ops only: rota, sales, GP, weather, reviews, invoices, no personal data.
- Family sees full Mission Control.
- RLS: staff API call sets `app.current_entity = '1,2'`; family `app.current_entity = 'all'`.

Vault secrets:
- `secret/dashboard/staff-bcrypt` and `secret/dashboard/jo-bcrypt`.
- Provisioned via `u47-dashboard-creds.sh` (interactive, prompts for plaintext, writes hash to Vault).

**Acceptance**:
- `curl -I http://100.104.82.53/staff/` → 401; with creds → 200.
- Staff page renders 0 rows for entity_id IN (3,4).
- Family page unchanged from current behaviour.

### Track 9 — 52-week recurring task suggester (~2 hr)

(Unchanged from the original U47 plan — see prior content.)

Weekly Sonnet job (`u47-recurring-task-suggester.sh`, cron Mon 09:00) mines
emails from 52 weeks ago for periodic patterns. New table
`recurring_task_suggestions`. Telegram digest Monday 10:00. Action Queue card.

### Track 10 — Reviews scraper (~2 hr)

(Unchanged. TripAdvisor via info@ Gmail OAuth in Playwright; Google Reviews via
Business Profile API on admin@. INSERT into existing `guest_reviews` table.
Drafter from U39 picks up.)

### Track 11 — STATUS/STRETCH/SPEC docs (~30 min)

- STATUS.md: U47 wrap.
- STRETCH.md: tick the items here as shipped; promote any uncovered to numbered sections.
- SPEC.md: §7.10 review-scraper auth model, §7.11 weather-as-forecast input, §7.12 sales-per-staff attribution model.

## Total

~13 hr — too big for one autonomous run. **Suggested split:**

- **U47a (UX repairs + GP fix + pub live ops + weather backfill + classifier queue)** ≈ 6 hr — high user-value, Jo asked for these directly.
- **U47b (workforce repairs + sales-per-staff attribution)** ≈ 3 hr.
- **U47c (52-week + reviews scraper + access split)** ≈ 4 hr — original U47 content.

## Anti-scope

- **No SDD migration** — U48.
- **No Wix integration** — U48.
- **No Authelia full forward_auth** — U48 (still depends on Tailscale cert + FQDN).
- **No new SPEC §7 sections** unless implementation requires them.
