# 2026-05-15 — U78: Clover statements + account_property_map registry

Two scan-driven flows wired into the Paperless ingest pipeline.

## Clover merchant statements → `clover_batches`

Brother ADS-2800W scans of monthly Clover statements now feed
`clover_batches` (one row per daily settlement batch), exposed daily via
`v_clover_daily` (same shape as `v_dojo_daily` for uniform joining).

**Why batch-level, not per-transaction:** the statement PDF only exposes
daily settlement totals split by card type. Per-transaction data lives in
the Clover dashboard (no daily API access yet). The user explicitly opted
for batch-level reconciliation against accommodation cashing-up rather
than waiting for API access.

**Sanity check:** March 2026 batches sum to £4,858.85 — matches the
statement's "Total Amount Submitted" exactly. Feb + Apr partially loaded
(some OCR'd source lines had `,` ↔ `.` swaps and missing columns; the 33
clean lines went in, 15 OCR-mangled lines skipped).

When the Clover dashboard becomes available daily, sibling
`clover_transactions` (per-transaction) can be added without disturbing
`clover_batches`.

## Utility bills → `vendor_invoice_inbox` via `account_property_map`

New registry: `(vendor_domain, account_number) → (entity_id, property_id,
site, category_canonical)`. The ingest path:

1. `u78-route.py` (invoked at the tail of `u62-paperless-sync.sh`)
   classifies new `documents` rows: Clover statement vs utility bill vs
   other.
2. `u78-ingest-utility.py` matches a `parse_<vendor>(ocr)` profile and
   pulls `(account_number, gross, dates, address)` out.
3. Account number normalised (digits only) → looked up in
   `account_property_map`.
   - **Hit:** insert `vendor_invoice_inbox` row with mapped entity +
     property; existing P2 extractor + Xero pipeline takes it from there.
   - **Miss:** insert with `status='needs_mapping'` AND open a
     `bot_instructions` row (`lane=data`, `realm=owner`) containing the
     exact `INSERT INTO account_property_map …` SQL pre-filled, so the
     next session-start surfaces the prompt.

**Why a separate registry, not a column on `properties`:** multi-property
accounts and shared-meter cases exist (single bill for two flats); the
registry handles that without forcing `properties` into a 1:N with
vendors.

## Why the `*/15` cron-tail wire-up rather than a watcher

`u62-paperless-sync.sh` already runs `*/15` and is the only thing inserting
into `documents` from Paperless. Tailing a single line
(`python3 /home_ai/scripts/u78-route.py || …`) to that script is one less
moving part than a fresh systemd watcher or inotify daemon. Cost: routing
lags up to 15 minutes from scan-drop.

## Deferred

- **U79** — extend `v_card_reconciliation` to add an `accom` leg matching
  `v_clover_daily.gross_sales` to `accommodation_bookings` revenue per day.
  Today U78 stores Clover; U79 actually reconciles it.
- Adding more utility vendors (EDF, British Gas, …) = one new
  `parse_<vendor>(ocr)` function in `VENDOR_PROFILES`. No schema change.

## Artefacts

- Migration: `V96__clover_batches_and_account_map.sql`
- Scripts: `u78-ingest-clover.py`, `u78-ingest-utility.py`, `u78-route.py`,
  `u78-run.sh`
- Hook: `u62-paperless-sync.sh` tail
- Commit: `c70f905`
