# U152 — Staff + restaurant + cash recon UI

**Prereqs**: U135 (schemas + slugs), U146 (realm pivot complete), U151 (pipeline stability).

**Realm**: `work`.

**Remote vs in-person**: 100% remote.

**Why this sprint exists**: U135 shipped Tanda + cash recon + holidays SCHEMAS and SLUGS, but the React surfaces never got built. `/work/staff` is a placeholder. 371 rows of `till_reconciliation` have zero surface. Restaurant page is bare. These are the daily-driver surfaces that determine whether staff can actually use the system.

## Tracks

### T1 — `/work/staff` page rebuild (~2 hours)

**Realm**: `work`.

**Build**:
- Four-card row at top: holidays-this-week, birthdays-this-week, bank-hols-next-30d, labour-cost-this-week.
- Tanda rota strip (today + next 6 days): use `dashboard_week_strip` data joined with shifts.
- Per-staff card: name, hours-this-week, holiday-balance, next-shift.
- Slugs (all already live): `staff_holidays_next_30d` (T4 below), `staff_birthdays_next_30d` (T4), `bank_holidays_next_90d` ✓, `labour_recent_14d` ✓.

**Acceptance**: page renders with live data; mobile-readable (single column on <600px viewport).

### T2 — `/work/restaurant` page (~90 min)

**Realm**: `work`.

**Build**:
- Today's covers (lunch + dinner) using `today_restaurant` slug.
- Tomorrow's reservations with deposit status using `restaurant_reservations` + `breakfast_tomorrow`.
- VIP / repeat-guest flag using `repeat_arrivals_3d` cross-reference.
- Table-reminder candidates using `table_reminder_candidates` slug.

**Acceptance**: clear "next 24h" view with deposit / no-deposit colour coding.

### T3 — `/work/recon` page (~90 min)

**Realm**: `work`.

**Build**:
- Top tiles: count of ok / minor / mismatch / approximate from last 30 days (already exists at `/api/recon/summary`).
- Day-by-day list of recon outcomes for last 14 days.
- Drill-down on click: per-day `till_reconciliation` rows + `v_cash_variance_day` numbers.
- L2 exception list (`exceptions` table where status=open).

**Acceptance**: anomalies surface to top; clicking drills to detail; staff can see what reconciled cleanly vs needs investigation.

### T4 — Two missing staff slugs (~30 min)

**Build**: V181 migration adding `staff_holidays_next_30d` + `staff_birthdays_next_30d` slugs (referenced by U135 plan but never created).

```sql
INSERT INTO query_whitelist (slug, ...) VALUES
  ('staff_holidays_next_30d', ...),
  ('staff_birthdays_next_30d', ...);
```

**Acceptance**: slugs return data via `/api/finance/slug/...`.

### T5 — Trail action queue tile on `/work/today` (~45 min, requires Trail base URL from in-person packet)

**Build**: new slug `trail_overdue_actions` selecting from `trail_reports` where `tasks_overdue > 0`. Add to `frontend_action_queue` UNION.

**Acceptance**: when Trail reports an overdue task, it appears at top of `/work/today` action queue within the next hourly poll.

## Done criteria

- `/work/staff`, `/work/restaurant`, `/work/recon` all render with live data.
- All three pages pass a manual usability check on mobile (iPhone Safari, Android Chrome).
- A staff member, given the URL, can find: today's rota, tomorrow's reservations, last week's recon variance — within 30 seconds each.

## Risk

Low. Backend (slugs + schemas) all proven. This is React + Tailwind work on existing patterns.

## Outcome trigger for U153

Once U152 lands, U153 (multi-user RBAC) can begin. The UI needs to exist before per-staff identity makes sense.
