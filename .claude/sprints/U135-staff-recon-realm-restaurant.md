# U135 — Staff page, daily reconciliation, realm enforcement, restaurant rota

**Prereqs**: U134 shipped (Trail, day-view drilldown, week-strip extras, rooms-this-week, breakfast).

**Realm**: `work` (most), plus an explicit `cross-cutting` track to enforce realm separation on the Admin page.

**Remote vs in-person**: ~100% remote.

**Why this sprint exists**: The /app/staff page is the lowest-information surface on the dashboard right now. Tanda sync is actually healthy (verified — see Findings) but the page doesn't show it. Cash reconciliation has 371 rows of infrastructure with zero surfacing. Personal data leaks onto work pages. Dojo daily ingest is silently stale (5 days behind). The restaurant page lacks operational signal. This sprint resolves all of those plus the day-view-aware refinements Jo asked for.

## Pre-sprint findings (verified 2026-05-19)

| Question | Answer |
|---|---|
| Tanda sync working? | **Yes**. `u29-workforce-sync.sh` and `u47-tanda-timesheets-sync.sh` both ran 02:15-02:20 UTC today, HTTP 200, 92 shifts seen/8 inserted/84 updated. 1,562 rows in `workforce_shifts` through 2026-06-09. |
| Why does the staff page look broken? | The frontend has no slug-driven content there yet — it's a placeholder. Data is fine; surfacing is missing. |
| Dojo daily import? | **STALE**. Last transaction 2026-05-14; today 2026-05-19. **No Dojo cron exists.** `dojo-import.py` ran manually historically. |
| Reconciliation already started? | **Yes**: `till_reconciliation` (371 rows), `reconciliation_flags` (6 rows), `v_cash_variance_day` (405 rows). Scripts `u67-recon-l1.sh`, `u68-recon-l2.sh`, `u68-recon-l3.sh`, `u68-recon-orchestrator.sh` exist. **No slugs surface any of it.** |
| Caterpay / Collins deposit tables? | **Missing** — `restaurant_reservations` has no `deposit_pence` column. Need to add. |
| Holiday + birthday data? | `holiday_entitlement` + `holiday_requests` tables exist. Staff DOB lives in `staff_meta` (verify field name). No `bank_holidays` table — use a gov.uk API one-shot. |

## Tracks

### T1 — Restore Dojo daily import (~30 min)

**Realm**: `work`. **Status**: blocker for T6 reconciliation.

**Build**:
- Investigate why `dojo-import.py` stopped — likely log or cred issue.
- Install cron entry: `30 5 * * * /home_ai/scripts/dojo-import.py >> /home_ai/logs/dojo-import.log 2>&1` (05:30 — before reconciliation runs at 06:00).
- Backfill last 5 days manually.
- Surface `dojo_last_import_age_hours` as a new slug for the Back-end page status check.

**Acceptance**: `SELECT max(transaction_date) FROM dojo_transactions` ≥ CURRENT_DATE - 1; cron in crontab; backfill complete.

---

### T2 — Bold "rooms still to sell this week" on daily dashboard (~10 min)

**Realm**: `work`.

**Build**:
- Surface `roomsWeek.room_nights_unsold` on the homepage in a prominent place (already exists in `rooms_week_economics` slug from U134 T4).
- Render as a separate bold callout above the 4-card row: e.g. `"11 nights still to sell this week"` in `text-xl font-bold text-amber-500`.
- If unsold = 0: render `"Fully booked this week 🎉"` in `text-good`.

**Acceptance**: KPI prominent on every dashboard load; updates with date-view.

---

### T3 — Collins deposits on week-strip + restaurant reservations schema (~45 min)

**Realm**: `work`.

**Build**:
- `V154__u135_restaurant_deposit_column.sql` — add `deposit_pence INTEGER` and `deposit_paid_at TIMESTAMPTZ` columns to `restaurant_reservations` (currently absent).
- Extend `scripts/u101-harvest-collins-reservations.py` to parse deposit lines from the Collins email (those that include "deposit paid £NN" or similar).
- Backfill recent Collins emails into the new column.
- Extend `dashboard_specials_next_7d` slug to also include non-group reservations where `deposit_pence > 0` (booking name + amount).
- Frontend: in the strip day-tile "Groups" block, show deposit-bearing reservations with a `£` glyph + amount + name (not just party_size).

**Acceptance**: a known recent Collins booking with a deposit shows up on the strip with `£25 · Smith party 4`.

**Open question for Jo**: are Collins deposits flat per booking, or per-pax? Affects schema (single `deposit_pence` vs per-line).

---

### T4 — Staff page: Tanda status, per-staff attribution, holidays, birthdays (~150 min, biggest track)

**Realm**: `work`.

**Build**:
- `V155__u135_staff_page_slugs.sql` — six new slugs:
  - `staff_tanda_sync_status`: last sync timestamp + row count for the back-end status row.
  - `staff_on_rota_today` (param `:date`): list of staff working that date with team + start/end times + cost.
  - `staff_attribution_per_hour` (params `:date_from`, `:date_to`): cross-references `v_workforce_shifts_costed` with `touchoffice_department_sales` to attribute revenue per person-hour, by team. Returns: staff_id, name, team, hours, cost, attributed_revenue, gp_per_hour, rank.
  - `staff_upcoming_holidays` (param `:date`, default = CURRENT_DATE): approved + pending holiday requests starting in the next 28 days, joined to staff names.
  - `staff_birthdays_next_30d`: from `staff_meta.date_of_birth` (verify column), staff whose birthday falls in next 30 days.
  - `staff_dojo_tips_today` (param `:date`): tip total per staff (if Tronc allocation is in `dojo_transactions` tip rows; if not, surface tip pool total only).
- Frontend `app/staff/page.tsx` rewrite:
  - **Date picker** at top: lets Jo set the date window (default = current week Monday).
  - **Tanda sync status row**: green/amber/red dot based on last-sync age.
  - **On rota today**: list grouped by team, with cost-per-shift + team subtotal.
  - **Attribution table**: sortable by `gp_per_hour`, with rank column, filterable by team. Date-window controlled by the picker.
  - **Tips today**: 1 line per staff (or pool total).
  - **Upcoming holidays**: list, next 28 days.
  - **Birthdays this month**: list, next 30 days.

**Acceptance**:
- Staff page populated from real data.
- Sorting + filtering on attribution table works client-side.
- Date picker changes the attribution window.
- Tanda status row reflects this morning's 02:15 successful sync.

**Open question for Jo**:
1. Revenue attribution model — proportional by team-hours? By department-revenue ratio? Currently `v_daily_labour_by_team` joins by team only; per-person attribution within a team needs an allocation rule.
2. Tips — are they via Tronc card-machine (Dojo)? Cash tips manual entry?

---

### T5 — Restaurant page: kitchen team + costs today (~30 min)

**Realm**: `work`.

**Build**:
- Reuse `staff_on_rota_today` slug from T4 with `:date = today`.
- New section on `app/restaurant/page.tsx` titled "Kitchen team on today":
  - Filter to `team = 'kitchen'` (the slug returns all teams).
  - Show per-person row: name, start–end times, hours, cost.
  - Subtotal: total kitchen hours, total kitchen cost.

**Acceptance**: today's kitchen rota visible with names + costs; subtotal correct.

---

### T6 — Daily reconciliation surface + cash-up flow (~180 min, biggest functional track)

**Realm**: `work`. **Depends**: T1 (Dojo daily fresh).

**Build**:
- New tables `V156__u135_cashup_inputs.sql`:
  ```sql
  CREATE TABLE cashup_inputs (
      id BIGSERIAL PRIMARY KEY,
      site            TEXT NOT NULL CHECK (site IN ('malthouse','sandwich')),
      cashup_date     DATE NOT NULL,
      till_id         TEXT NOT NULL,       -- e.g. 'till_1', 'till_2'
      z_read_pence    INTEGER,             -- TouchOffice Z-read total for this till
      cash_taken_pence INTEGER,             -- manual entry: cash counted out of till
      card_pence      INTEGER,             -- from Dojo
      caterpay_pence  INTEGER,             -- accommodation deposits via Caterbook
      collins_deposit_pence INTEGER,        -- restaurant deposits via Collins
      manual_notes    TEXT,
      entered_by      TEXT,
      entered_at      TIMESTAMPTZ DEFAULT now(),
      realm           TEXT NOT NULL DEFAULT 'work',
      UNIQUE (site, cashup_date, till_id)
  );

  CREATE TABLE safe_movements (
      id BIGSERIAL PRIMARY KEY,
      movement_date   DATE NOT NULL,
      site            TEXT NOT NULL,
      direction       TEXT NOT NULL CHECK (direction IN ('to_safe','from_safe')),
      amount_pence    INTEGER NOT NULL,
      notes           TEXT,
      entered_by      TEXT,
      entered_at      TIMESTAMPTZ DEFAULT now(),
      realm           TEXT NOT NULL DEFAULT 'work'
  );
  ```
- New slugs (V157):
  - `cashup_reconciliation_today` (param `:date`, `:site`): joins Z-reads + Dojo cards + Caterpay + Collins + cashup_inputs.cash_taken + safe_movements. Returns one row per site per till plus a totals row, with `variance_pence` columns per source.
  - `safe_running_balance` (param `:site`): running balance from start-of-month over `safe_movements`.
- Frontend new page `app/tasks/cashup/page.tsx` (or extend tasks/page.tsx):
  - **End-of-day cash-up form** (per site, side-by-side panels for Malthouse and Sandwich Bay).
  - For each till: pre-populated Z-read, Dojo card total; one editable Cash field; "submit" upserts into `cashup_inputs`.
  - Reconciliation calc panel: expected vs actual + variance per till + site total; red highlight when variance > £5.
  - Caterpay + Collins deposit columns auto-populated from their respective tables (Caterpay reads from `caterbook_room_nights` or similar; Collins from new `restaurant_reservations.deposit_pence` column from T3).
  - Safe-balance row: today's movements + running balance.

**Acceptance**:
- Submit cash-up for one till → row in `cashup_inputs`.
- Variance calc matches `total_cards + cash_taken - z_read`.
- Safe movements update running balance.
- Errors highlighted in red.

**Open question for Jo**:
1. How many tills per site? (Malthouse 2 — pub + restaurant? Sandwich Bay 1?)
2. Is Caterpay a separate Dojo merchant or part of the same? Affects whether deposits are double-counted.

---

### T7 — Admin page realm enforcement (~30 min)

**Realm**: `cross-cutting`.

**Build**:
- Audit current `/app/admin` slugs — `mortgages_all`, `private_vehicles`, `children`, `private_docs_kpis` etc. should NOT surface on a `work` page.
- `V158__u135_admin_realm_split.sql`: separate slugs into two namespaces:
  - `admin_work_*` — pub kitchen ops, supplier admin, document review queue
  - `admin_personal_*` — separately surfaced under a (future) `/app/private` route, NOT on `/app/admin`
- Frontend `app/admin/page.tsx`: only call work-realm slugs; remove any private-realm imports.
- Add a server-side guard in lib/db.ts that refuses to run slugs with `realm != current_realm` unless the user has `Remote-Groups: owner`. Currently `set_realm('owner')` is hardcoded — change to read from `Remote-Groups` header (already passed via Caddy forward_auth).

**Acceptance**:
- `/app/admin` shows ONLY work-realm tiles.
- Mortgages, vehicles, children no longer fetchable from /app/admin's surface.
- A future /app/private path will be the home for personal data.

---

### T8 — Back-end page: slug health + API costs + errors (~60 min)

**Realm**: `work` (this is build telemetry, not personal).

**Build**:
- New slugs (V159):
  - `backend_slug_health`: per-slug `last_called_at`, `error_rate_24h`, `avg_latency_ms` from `audit_log` (audit_log already records `action='slug_call'` — verify).
  - `backend_ai_cost_today`: sum of `log_ai_usage.cost_usd` for today.
  - `backend_errors_24h`: rolling 24h error count by service.
  - `backend_dojo_last_import_age_hours`: how stale Dojo import is.
  - `backend_tanda_last_sync_age_hours`: how stale Tanda sync is.
- Frontend `app/backend/page.tsx`:
  - Replace placeholders with real slug-driven KPI tiles.
  - "Stalled imports" red banner if any sync > 24h old.

**Acceptance**:
- Stale Dojo flagged red until T1 cron runs.
- Healthy Tanda flagged green.
- AI cost today is a live number.

---

## Migration order

| # | File | Track |
|---|---|---|
| V154 | `u135_restaurant_deposit_column` | T3 |
| V155 | `u135_staff_page_slugs` | T4 |
| V156 | `u135_cashup_inputs_tables` | T6 |
| V157 | `u135_cashup_reconciliation_slugs` | T6 |
| V158 | `u135_admin_realm_split` | T7 |
| V159 | `u135_backend_health_slugs` | T8 |

## What this sprint does NOT do

- Does **not** automate full closing of cash variances — manual cash entry is still required; the tool just compares + highlights.
- Does **not** wire Tronc tip allocation from cash tips — only card-tip totals from Dojo.
- Does **not** rebuild the existing reconciliation L2/L3 scripts (`u67`/`u68`) — surfaces what they produce.
- Does **not** add a per-month private dashboard at /app/private — defer T7's future surface to a follow-up; this sprint just removes personal data from /app/admin.

## Anti-regression checks

- Day-view URL pattern still works for the new slugs that accept `:date`.
- `frontend_today_gross` still respects the U132 fallback for stale TouchOffice data.
- Realm guard on lib/db.ts doesn't break any /app/ pages that already call work-realm slugs.

## Follow-on sprints

- **U136** — full `/app/private` surface (personal finance, family, vehicles, mortgages) with realm-gated route.
- **U137** — Tronc cash-tip entry + allocation rules; payslip generation hook.
- **U138** — close-the-loop on Trail compliance (T1 from U134 still skeleton).
