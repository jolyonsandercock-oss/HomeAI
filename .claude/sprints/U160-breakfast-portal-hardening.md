# U160 — Breakfast pre-order portal hardening

**Prereqs**: U106 breakfast workflow already built (HTML form + `/api/breakfast/submit` endpoint, public + signed-token auth).

**Realm**: `work`.

**Remote vs in-person**: 100% remote (T2 may need kitchen-staff trial — wraps into U158 dress rehearsal).

**Why this sprint exists**: U106 shipped the public-form-submit plumbing but the loop isn't closed:
- No per-stay QR code generated (guests need direct URL).
- Submissions just sit in `breakfast_orders` — kitchen-staff have nowhere to see them.
- Forecast view doesn't exist (kitchen needs "tomorrow we need X portions of Y").
- Orders not linked back to `restaurant_reservations` so guests get table reminders too.

## Tracks

### T1 — Per-stay QR code generation (~45 min)

**Build**:
- Slug `caterbook_stays_qr_pending` — returns active reservations missing a QR.
- `scripts/u160-qr-mailer.py` — for each pending stay, generate a signed-token URL (`/breakfast?stay=<token>`) and embed as a QR image in their arrival-day email. Token includes stay-id + expiry.
- Cron `0 8 * * *` runs through pending stays for arrivals in next 2 days.

**Acceptance**: a guest with check-in tomorrow gets their pre-arrival email with a QR; scanning lands on the breakfast form pre-populated with their stay.

### T2 — Kitchen-staff view (`/work/kitchen`) (~75 min)

**Build**:
- React page `homeai-frontend/app/kitchen/page.tsx`.
- Tomorrow's breakfast orders table (item, count, allergens, table preference).
- Yesterday-evening cut-off marker: orders submitted after 22:00 yesterday show with warning.
- Print-friendly view for kitchen wall.
- Gate behind `Remote-Groups: kitchen-staff` OR `manager` OR `owner` per U153 RBAC.

**Acceptance**: kitchen-staff account logs in, sees tomorrow's orders; can print on phone.

### T3 — Forecast slug (~30 min)

**Build**: `frontend_breakfast_forecast` slug — tomorrow's count per item, grouped by table-time slot.

```sql
SELECT
  bo.item,
  bo.allergen_notes,
  count(*) AS portions,
  array_agg(DISTINCT bo.requested_time ORDER BY bo.requested_time) AS slots
FROM breakfast_orders bo
WHERE bo.requested_date = CURRENT_DATE + 1
GROUP BY bo.item, bo.allergen_notes
ORDER BY portions DESC;
```

**Acceptance**: slug returns aggregated counts.

### T4 — Auto-link to restaurant_reservations (~45 min)

**Build**: extend `/api/breakfast/submit` handler — when a breakfast order arrives, also INSERT/UPDATE `restaurant_reservations` row for that guest+date so they get table reminders via existing `table_reminder_candidates` slug.

**Acceptance**: submitting a breakfast order creates a matching restaurant_reservations row.

### T5 — Operational dashboard tile (~30 min)

**Build**: `breakfast_tomorrow` slug already exists. Add a tile on `/work/today`:
- "Tomorrow's breakfast: N orders (X portions)"
- Color: green if all guests covered; amber if check-in tomorrow but no order yet.

**Acceptance**: tile renders; clicking goes to /work/kitchen.

## Done criteria

- Guest can scan QR + submit breakfast pre-order self-service.
- Kitchen-staff can view tomorrow's forecast on their phone before bed.
- Pre-orders auto-link to restaurant_reservations.
- /work/today shows breakfast forecast count.

## Risk

Low. Schema + form-submit already exist. This is pipeline closure work, not new architecture.

Related: [[u106-breakfast-form]] (predecessor), [[u153-multi-user-rbac]] (kitchen-staff role definition).
