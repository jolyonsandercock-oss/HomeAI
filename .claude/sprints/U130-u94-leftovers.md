# U130 — U94 leftovers: Booking.com ingest + sales scrape + source naming

**Prereqs**: [[U94]] T1/T2/T6/T7/T8/T9 shipped (see U94 superseded note for delivery map).

**Realm**: `work` (all accommodation/booking data).

**Remote vs in-person**: ~100% remote. All three tracks are autonomous overnight work.

**Why this sprint exists**: Three concrete gaps from the U94 plan never landed when the work was redistributed across U95-U129. T1 (~33 Booking.com emails sitting unprocessed) is the only material gap — real bookings with real money attached. The other two are data-hygiene polish.

## Tracks

### T1 — Booking.com direct ingester (~45 min)

**Realm**: `work`.

**Build**:
- `scripts/u130-harvest-bookingdotcom.py` — pull `from:*booking.com*` 36-month window from info@, admin@, jo@.
- Parse: confirmation number, lead guest, arrival, departure, room, total, payment status.
- INSERT into `accommodation_bookings` with `source='booking.com'` (lowercase, no spaces — see T3 naming rules).
- INSERT into `booking_messages` per email.

**Acceptance**:
- ≥1 row per Booking.com confirmation in inbox (current count = 33 emails).
- Cancellation emails update `status='cancelled'` on the existing row.
- Re-run is idempotent on `source_ref` (Booking.com confirmation number).

---

### T2 — Caterbook `/reports/sales` per-booking revenue (~60 min)

**Realm**: `work`.

**Build**:
- Extend the existing `u28-caterbook-daily.sh` Playwright session to GET `/reports/sales` for the previous day.
- Parse itemised per-booking spend (room + extras + bar + food).
- New table `caterbook_booking_sales` via V110 migration:
  ```sql
  CREATE TABLE caterbook_booking_sales (
      id BIGSERIAL PRIMARY KEY,
      caterbook_ref TEXT NOT NULL,
      sale_date DATE NOT NULL,
      room_pence INTEGER, food_pence INTEGER, bar_pence INTEGER, extras_pence INTEGER,
      total_pence INTEGER NOT NULL,
      ingested_at TIMESTAMPTZ DEFAULT now(),
      realm TEXT NOT NULL DEFAULT 'work',
      UNIQUE (caterbook_ref, sale_date)
  );
  ```
- Link back to `accommodation_bookings` by `(checkin_date, guest_name)` fuzzy match into `accommodation_bookings.total_revenue_pence` (new column).

**Acceptance**:
- Each `accommodation_bookings` row with a recent checkout has `total_revenue_pence` populated.
- Re-run is idempotent on `(caterbook_ref, sale_date)`.
- Pulls last 36 months as backfill on first run.

---

### T3 — Source naming consistency (~15 min)

**Realm**: `work`.

**Build**:
- One-shot SQL:
  ```sql
  UPDATE accommodation_bookings SET source='airbnb'  WHERE source IN ('Airbnb');
  UPDATE accommodation_bookings SET source='agoda'   WHERE source IN ('agodaycs');
  -- (re-run after T1 lands so 'booking.com' is the only Booking variant)
  ```
- Add a CHECK constraint or trigger on `accommodation_bookings.source` enforcing lowercase, allowed values: `('hotel_email','airbnb','caterbook_airbnb','agoda','caterbook_agoda','ctrip.com','caterbook_ctrip','booking.com','encounter','caterbook_web')`.
- Update U96/U97/U98 ingester scripts to write lowercase source values (guard against future drift).

**Acceptance**:
- `SELECT DISTINCT source FROM accommodation_bookings` returns only lowercase values from the allowed list.
- Constraint blocks future inserts with disallowed source values.

---

## What this sprint does NOT do

- Does **not** build Encounter Walking Holidays ingest — 0 inbox volume; revisit only if Jo confirms the `rooms-encounter` Gmail label has been set up and emails started arriving.
- Does **not** build OYO / Expedia direct ingest — 0 inbox volume.
- Does **not** redesign the booking-row schema or migrate existing rows beyond the source-rename.

## Follow-on sprints

- None planned. After U130 the U94 surface is closed-out.
