# U149 — Finish the /app surfaces

**Prereqs**: U133/U134/U135 sprints shipped (week strip, day-view, staff page scaffold, Trail). U132 (all slugs live).

**Realm**: `work` (operational dashboards).

**Remote vs in-person**: 100% remote.

**Why this sprint exists**: Three sprints in May shipped schemas + slugs but left ingest pipelines + UI surfaces in scaffold state. Each gap costs Jo daily signal that already has the infrastructure to support it.

## Tracks

### T1 — Tide times scrape cron (~60 min)

**Realm**: `work`.

**Why**: V144 (U133 T2) created `tide_times` table. No data has been loaded; no cron exists.

**Build**:
- `scripts/u149-tide-scrape.py` — fetch tidetimes.org.uk for Tintagel + Boscastle, parse HTML, upsert `tide_times` rows for next 14 days.
- Cron 04:00 daily (before dashboard wakes).
- Slug `tides_this_week` already exists; verify it returns data once table is populated.

**Acceptance**: `SELECT count(*) FROM tide_times WHERE tide_date >= CURRENT_DATE` >= 28 (14 days × 2 tides/day).

### T2 — Reviews scrape pipeline (~2 hours)

**Realm**: `work`.

**Why**: U133 T6 added the schema + scaffold; the actual scraper was never written.

**Build**:
- `scripts/u149-reviews-scrape.py` — pulls Google Reviews + TripAdvisor recent reviews via direct page scrape (playwright since no API).
- Cron once daily.
- Slug `recent_reviews` surfacing on /work/today.
- Stretch: sentiment classification via Haiku (small batch, cheap).

**Acceptance**: 7 days of reviews ingested; appears on /work/today reviews tile.

### T3 — Dojo daily import cron (~30 min)

**Realm**: `work`.

**Why**: U135 findings flagged Dojo as STALE — last transaction 2026-05-14. `dojo-import.py` exists but no cron.

**Build**:
- Investigate why historical run stopped (probably credential expiry).
- `30 5 * * *` cron entry.
- Backfill 2026-05-15 → today manually.
- New slug `dojo_last_import_age_hours` for backend health.

**Acceptance**: `SELECT max(transaction_date) FROM dojo_transactions >= CURRENT_DATE - 1`.

### T4 — Staff page holidays + birthdays (~60 min)

**Realm**: `work`.

**Build**:
- New slug `staff_holidays_next_30d` joining `holiday_entitlement` + `holiday_requests`.
- New slug `staff_birthdays_next_30d` using `staff_meta.date_of_birth`.
- New slug `bank_holidays_next_60d` — one-shot import from gov.uk JSON API into new `bank_holidays` table.
- Wire into /work/staff page (top-right card stack).

**Acceptance**: cards render with this month's data.

### T5 — Trail action queue surface (~45 min)

**Realm**: `work`.

**Why**: U134 T1 ingested Trail reports but the overdue items aren't surfaced as actions.

**Build**:
- New slug `trail_overdue_actions` selecting from `trail_reports` where `tasks_overdue > 0`.
- Add to `frontend_action_queue` UNION in /work/today.

**Acceptance**: overdue Trail tasks appear on /work/today action queue.

## Done criteria

- /work/today shows tides, reviews, Trail-overdue, staff-holidays-this-week.
- /work/staff shows holidays + birthdays + bank-holiday calendar.
- All 5 new cron entries land in crontab; logs show successful runs.

## Risk

Low. Each track is additive — schemas exist, just wiring + ingest. Reviews scrape is fragile (Google may rate-limit) but failure mode is "no new reviews", not breakage.
