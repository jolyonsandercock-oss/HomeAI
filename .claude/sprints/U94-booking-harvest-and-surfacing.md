# U94 — Booking harvest, surface + thread linking (36-month horizon)

**Prereqs**: U92 shipped. `accommodation_bookings` schema exists.

**Realm**: `work` (all data is business).

**Remote-doable**: ~85%. Caterbook web scraping (T6) needs Playwright + stored creds — already in place since U27 but worth verifying. Everything else is autonomous.

**Why this sprint exists**: bookings + reservations + restaurant traffic flow into 3 inboxes (info@, admin@, jo@) + 2 web apps (Caterbook, Collins). Right now `accommodation_bookings` has 8 rows, no unified surface for "what's happening this week", no reconciliation between booking-email and the deposit/payment that follows. Jo needs one searchable table for 36 months of activity + a daily dashboard panel.

**Overnight-autonomous**: T1-T3 yes. T4 (Caterbook scraping) needs cred verification — defer to session 2. T7 (UI) needs design — defer.

## Sources catalogued

| Source | Account | Filter | Pattern (subject / from) |
|---|---|---|---|
| **bookings@hotel-email.com** | info | "New Booking Received" + from filter | Subject "New Booking Received". Body has `Booking Reference: NNNN`, `Lead Guest:`, `Arriving:`, `Departing:`, `Room Type:`, `Rateplan:`, `Deposit paid:`, `Balance due:` |
| **Agoda** | info, admin, jo | "Agoda" | Various — confirmation, modification, cancellation |
| **Airbnb** | info, admin, jo | "airbnb" | Reservation confirmed / pre-approved / change of plans |
| **Encounter Walking Holidays** | info | "rooms-encounter" label | Group bookings, deposit invoices, balance invoices |
| **Booking.com confirmation** | info, admin, jo | "Booking.com confirmation" | OTA bookings |
| **OYO / Expedia** | info, admin | "OYO" / "Expedia" | OTA bookings |
| **Caterbook web** (T6) | n/a | `/booking/search` daily scrape | Source of truth for reconciliation |
| **Caterbook sales** (T6) | n/a | `/reports/sales` daily scrape | Per-booking total spend |
| **Collins / DesignMyNight** | info, admin | "noreply@designmynight.com" or "Collins" | Restaurant reservations — separate flow, links to its own URL |
| **Amazon** | info, admin, jo | "Amazon" | Invoice ingest (separate concern — feeds into `vendor_invoice_inbox`) |

## Schema additions

```sql
-- accommodation_bookings already exists. Need extensions:
ALTER TABLE accommodation_bookings ADD COLUMN IF NOT EXISTS
    booking_type TEXT,              -- 'accommodation' | 'restaurant'
    ingested_at TIMESTAMPTZ DEFAULT now(),
    source_email_id TEXT,           -- Gmail message_id (clickable link)
    source_account TEXT,            -- 'info' | 'admin' | 'jo'
    payment_status TEXT,            -- 'unpaid' | 'deposit_paid' | 'paid'
    payment_reference TEXT,         -- ref linking to bank_transactions / dojo / stripe
    canonical_id BIGINT REFERENCES accommodation_bookings(id);  -- de-dup link

-- New: messages table for thread view
CREATE TABLE booking_messages (
    id BIGSERIAL PRIMARY KEY,
    booking_id BIGINT REFERENCES accommodation_bookings(id),
    gmail_account TEXT NOT NULL,
    gmail_message_id TEXT NOT NULL,
    received_at TIMESTAMPTZ NOT NULL,
    from_address TEXT,
    subject TEXT,
    body_excerpt TEXT,
    UNIQUE (gmail_account, gmail_message_id)
);

-- New: restaurant_reservations (Collins). Separate because shape differs.
CREATE TABLE restaurant_reservations (
    id BIGSERIAL PRIMARY KEY,
    source_ref TEXT NOT NULL UNIQUE,
    reservation_at TIMESTAMPTZ NOT NULL,
    guest_name TEXT,
    guest_email TEXT,
    phone TEXT,
    party_size INTEGER,
    booking_type TEXT,  -- 'dinner' | 'lunch' | 'drinks'
    status TEXT,
    deposit_pence INTEGER,
    source_account TEXT,
    source_email_id TEXT
);
```

## Tracks

### T1 — Bookings ingester for `bookings@hotel-email.com` (~60 min)

**Build**:
- `scripts/u94-harvest-hotel-email-bookings.sh` — pull every "New Booking Received" email from `bookings@hotel-email.com` in info@ across last 36 months.
- Parse fields: Booking Reference, Lead Guest, Arriving, Departing, Room Type, Rateplan, Deposit paid, Balance due.
- INSERT into `accommodation_bookings` with idempotency on `source_ref` (booking reference).
- INSERT into `booking_messages` with the Gmail message_id for back-link.

**Acceptance**: ≥1 row per email; idempotent on re-run; `source_email_id` populated.

### T2 — OTA harvest (Agoda, Airbnb, Booking.com, OYO, Expedia) (~90 min)

**Build**:
- One ingester per OTA, each handling that OTA's confirmation email shape.
- INSERT into `accommodation_bookings` with `source='agoda'` etc.
- Status field captures `confirmed | modified | cancelled` from email patterns.

**Acceptance**: row per OTA confirmation; cancellations correctly mark status='cancelled'; no duplication across info/admin/jo (use Gmail message_id + booking ref).

### T3 — Encounter Walking Holidays from `rooms-encounter` label (~30 min)

**Build**:
- `rooms-encounter` label captures group bookings (multiple rooms, multiple nights).
- Parse: group name, party size, dates, deposit invoice references, balance invoice references.
- INSERT into `accommodation_bookings` with `source='encounter'`.
- The deposit + balance invoices link via existing `vendor_invoice_inbox` flow — cross-reference.

**Acceptance**: every Encounter group has a row; deposit + balance invoice IDs linked.

### T4 — Caterbook web scrape (`/booking/search`) — DEFERRED (~120 min)

**Build**:
- Playwright script: log into Caterbook, GET `/booking/search` daily.
- Parse table → upsert into `accommodation_bookings` with `source='caterbook_web'`.
- De-dupe key: `(source_ref, checkin_date)`. Any record matching an email-ingested booking (same dates + guest name) gets `canonical_id` linked.
- **DEFERRED**: needs cred verification + careful selector mapping. Session 2.

**Acceptance**: daily snapshot in `accommodation_bookings`. Caterbook is treated as source-of-truth: when it disagrees with an email-ingested row, Caterbook wins.

### T5 — Caterbook sales scrape (`/reports/sales`) — DEFERRED (~60 min)

**Build**:
- Same Playwright session, GET `/reports/sales` per-day.
- Parse itemised totals per booking → store in `caterbook_booking_sales` (new table) → link to `accommodation_bookings.id`.
- Surface as `total_revenue_inc_extras` on the booking row.

**Acceptance**: every booking has its food/bar/extras spend attached.

### T6 — Collins / DesignMyNight restaurant reservations (~45 min)

**Build**:
- `scripts/u94-harvest-collins.sh` — pull `from:noreply@designmynight.com` in info@ + admin@ 36-month window.
- Parse: Name, Email, Phone, Party size, Booking type, Reservation date/time, DMN ref.
- INSERT into `restaurant_reservations`.
- Capture the "View it in Collins: <URL>" so the dashboard can deep-link.

**Acceptance**: row per Collins email; deposit-payment emails (separate Collins subject) update payment_status.

### T7 — Amazon invoice ingest into `vendor_invoice_inbox` — DEFERRED (~45 min)

**Build**:
- Different from bookings: Amazon order confirmations + invoices go into the existing `vendor_invoice_inbox` table.
- Need vendor_domain match: `amazon.co.uk` + various `noreply@*amazon*` senders.
- Parse: order number, total, line items, shipping address.

**Acceptance**: rows in `vendor_invoice_inbox` tagged `vendor_domain='amazon.co.uk'`.

### T8 — UI surface (~120 min) — DEFERRED

**Build**:
- New page `/bookings` with searchable Tabulator table.
- Columns: date, price, booking ref, guest name, room, source, payment status, message thread count.
- Each row: clickable to `booking_messages` thread (modal or sidebar).
- Search facets: date range, source, price, name fuzzy.
- Tile on `/m` (mobile dashboard): "Today's arrivals + departures" with count + revenue.

**Acceptance**: page loads, search works, message thread modal opens with clickable Gmail-message back-links.

### T9 — Restaurant calendar page (~60 min) — DEFERRED

**Build**:
- New page `/reservations` with day-by-day calendar view of Collins bookings.
- Surface deposit-paid status per row.
- Daily dashboard tile: "Tonight's covers" + party-size sum.

## What this sprint does NOT do

- Does **not** build a new payment-reconciliation pipeline. Use existing `bank_transactions` + Dojo settlement matching for the payment link.
- Does **not** rewrite caterbook_daily_snapshots — that ingest stays; the new bookings table is in addition.
- Does **not** integrate with Stripe/PayPal directly.

## Tonight (this session)

- T1 hotel-email.com ingester — first concrete deliverable. Run for 36 months, get baseline data.
- Schema additions land as V100.
- Confirm dedup pattern works.

## Subsequent sessions

- T2 OTA ingest (Agoda/Airbnb/Booking/OYO/Expedia)
- T3 Encounter group bookings + invoice cross-link
- T6 Collins reservations
- T4+T5 Caterbook web scrape (needs cred verification)
- T7 Amazon → vendor_invoice_inbox
- T8 UI surface
- T9 Restaurant calendar page

## Anti-duplication rules

1. Within a single source: idempotency on `source_ref` (booking ref OR Gmail message_id).
2. Cross-source: if Caterbook row exists for same (checkin_date, guest_name), set `canonical_id` to Caterbook. Email rows become "messages" pointing at the canonical.
3. UI shows ONE row per canonical booking; message-thread count surfaces all linked emails.

## Open questions for Jo

1. **Caterbook creds** — confirm `secret/caterbook` still has working OAuth/session creds for `/booking/search` and `/reports/sales`?
2. **Encounter Walking Holidays deposit + balance flow** — are these separate emails? Do they reference the original booking ref?
3. **Amazon scope** — every purchase, or only "Atlantic Road" business purchases? (Some Amazon purchases will be personal.)
4. **Collins deposits** — do they show up as Stripe payments? If so, payment_reference links to which table?

## Acceptance for the whole sprint

- One canonical `accommodation_bookings` row per real-world booking, ≥36 months back.
- One `restaurant_reservations` row per Collins booking.
- Message thread queryable per booking (returns all related emails).
- `/bookings` page loads with searchable table.
- `/m` and daily dashboard show today's arrivals + tonight's covers.
- Sample of 5 random bookings verified end-to-end with originating email reachable via deep-link.
