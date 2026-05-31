# U232 — COGS capture completeness

**Realm**: work (ARTL). **Remote vs in-person**: scrapers need one in-person
pairing pass each (JolyBox local console, `DISPLAY=:0`). **Risk**: medium —
all writes are additive/shadow into `purchases`; the live risk is scraper
brittleness, not data loss.

**Why this sprint exists**: 100% of captured invoices today arrive by email
(`purchases.source='email'`, 622 rows). Paper, Dext-captured, and supplier-portal
invoices are uncaptured, so COGS is incomplete and GP% reads inflated (U147
session found food cost ~18% vs ~30% reality; Jan 2026 had zero captured COGS →
100% GP). This sprint closes the non-email channels and adds an honest coverage
signal so GP% is trustworthy-or-flagged rather than silently wrong.

## Current state (verified 2026-05-31)

- `purchases.source` is only ever `email` (admin 385 / info 161 / jo 76).
- `purchases.idempotency_key` is **UNIQUE** → imports may use
  `INSERT … ON CONFLICT (idempotency_key) DO NOTHING/UPDATE` (contrast with
  `events`, which has no unique key — AGENTS.md rule 7).
- The ladder (`scripts/projA/ladder.py`) already has the engine to turn raw
  invoice bytes into `purchases`: `pdf_to_text` (pdfplumber), `pdf_to_png_b64`
  (Claude vision for scans/photos), `extract_local` → cloud escalation, `gate`,
  `derive_realm`. It currently only ingests from Gmail (`fetch_pdf_bytes(acct,
  mid)`); it needs a raw-bytes entry point for new sources.
- Dext has **no API** ([[dext]] memory) and its notification emails carry no
  invoice data (subjects: "limit reached", "Unsuccessful document upload") — so
  the only route to Dext-captured data is scraping the Dext web UI.
- Playwright scraper patterns exist: `scrapers/dojo.py`, `scrapers/trail.py`,
  pairing via `scripts/pair-local.sh <name>`, storage in
  `data/playwright-state/<name>-storage.json` (gitignored), debug dumps via
  `_debug.dump_state` → `/home_ai/storage/scraper-debug/`.
- `bank_transactions` exists (cols incl. `transaction_date`, `amount` (negative
  = outflow), `description`, `category`, `realm`) → the honest coverage
  denominator.

## Track 1 — Dext scraper (the paper/photo channel)

Jo's Dext workflow (photograph paper invoices → Dext OCRs + extracts line items)
is mature and stays as-is. This track imports Dext's *output*.

**Build**:
- `services/playwright/scrapers/dext.py` + `/scrape/dext` and `/ingest/dext`
  endpoints on `homeai-playwright`, mirroring `dojo.py` structure.
- Login to the Dext web UI. **First task: characterise the auth** (Dext uses
  email/password; check for SSO/MFA like Dojo's Auth0+email-MFA). Creds →
  `secret/dext` in Vault. Auto-tick any "remember device".
- Navigate to the processed **Costs / Items** list. For each document pull the
  Dext-extracted fields: supplier, invoice date, net/VAT/gross, and line items
  (description, qty, unit price, line total) — Dext already OCR'd these, so **no
  re-extraction needed**; map fields directly (skip the ladder).
- Map → `purchases` (`source='dext'`, `account='dext'`,
  `idempotency_key='dext_'||<dext_doc_id>`, `is_invoice=true`, `gate_passed`
  per a field-completeness check) and `purchase_lines`. `SET LOCAL
  app.current_entity` + `home_ai.set_realm('work')` before writes (RLS).
  `INSERT … ON CONFLICT (idempotency_key) DO UPDATE` for re-runs.
- Where Dext line-item extraction is absent/partial, fall back to feeding the
  source PDF (if downloadable) through the existing ladder.
- Pairing: `scripts/pair-local.sh dext` from the JolyBox console.
- Cron: daily (align with `projA-daily` ~07:40). Add to host crontab + document.

**Acceptance**: a Dext-captured paper invoice appears in `purchases` with
`source='dext'`, correct totals, line items, and `realm='work'`; re-run is
idempotent (no duplicates); it shows in the `/invoices` verify lane and gets
auto-categorised by `propagate_vendor_categories()` when its vendor has a rule.

## Track 2 — Supplier portal scrapers (1–2, targets chosen after recon)

### T2.0 — Recon (do first; ~1h)
- For the top vendors by spend, determine the invoice delivery channel:
  portal-with-login / email-only / EDI / paper-only. Top candidates:
  St Austell Brewery (~£50k across name variants), J&R Foodservice (£29k, 151
  invoices), Atlantic Road Trading (£13k), Westcountry Fruit Sales (£5k).
- For each portal candidate: confirm a customer/trade portal exists, Jo has
  credentials, and invoices are downloadable as PDFs. Note MFA.
- **Pick 1–2** with the best (coverage £ ÷ build effort). Record the choice +
  rationale in this doc before building.

### T2.1+ — Per-portal scraper (one per chosen vendor)
**Build** (repeat per vendor):
- `services/playwright/scrapers/<vendor>.py` + `/scrape/<vendor>`, mirroring the
  Dojo pattern. Creds → `secret/<vendor>` in Vault. Pairing via `pair-local.sh`.
- Log in, list invoices, download new PDFs (track last-seen by invoice number /
  date to avoid re-downloading).
- Add a **raw-bytes entry point to the ladder** (`run_ladder` variant that takes
  PDF bytes + a source tag instead of a Gmail message id) and feed each PDF
  through it → `purchases` (`source='portal:<vendor>'`).
- Cron: daily or per the vendor's invoice cadence.

**Acceptance**: each chosen portal's recent invoices land in `purchases` with
`source='portal:<vendor>'`, pass the gate, and are idempotent across runs;
selector misses emit a debug dump + alert.

## Track 3 — Coverage indicator (honest GP%)

> **Increment 1 SHIPPED 2026-05-31** (V217 + slug `cogs_capture_coverage` +
> `/invoices` completeness strip). Self-contained (purchases-only): per-month
> captured COGS with a trailing-3mo flag (empty/low/ok). Live verify: 2026-01
> and 2025-05 flagged `low`; GP panel now warns when months are unreliable.
>
> **Increment 2 (bank-anchored true coverage) is BLOCKED — key finding:**
> `bank_transactions` is well-populated (10,141 rows, 2019–2026, fully
> categorised) but **~99% are tagged `realm='personal'`** (£4.28M) with only 87
> `realm='work'` rows (£66k). For a pub-scale business this is almost certainly
> the **business banking mis-classified as personal** — the same systemic realm
> mis-assignment seen on invoices (Western Supply, RCC Roofing). A
> captured-vs-paid coverage ratio needs that fixed first. **Recommend a
> dedicated realm-reclassification / data-quality sprint** (also fixes invoice
> realm accuracy and unblocks the work-realm rollout) — needs Jo's judgment on
> what is genuinely business vs personal; not safe to auto-retag 10k rows.

**Build**:
- Migration `V217__u232_cogs_coverage.sql`: view `v_cogs_coverage` —
  per (month, realm='work'): `captured_cogs` (Σ `purchase_lines.line_net` over
  is_invoice/gate_passed purchases), `supplier_outflow` (Σ |`amount`| of
  outflow `bank_transactions` classified as supplier spend — exclude payroll,
  rent, transfers, HMRC via `category`), `coverage_pct = captured/outflow`,
  `captured_vendor_count`. `security_invoker=true` (per U147 Phase A lesson).
- Slug `cogs_coverage_monthly` (realm='work', `approved_at=NOW()`).
- Frontend `/invoices`: a coverage strip (per-month coverage %, low months
  flagged). Qualify the GP% panel — show `coverage X%` next to it and render GP
  "provisional / low coverage" when `coverage_pct` below a threshold
  (`ops_thresholds`, default ~0.8).
- Optionally surface the same coverage caption on the `/sales` WIP COGS columns.

**Acceptance**: `/invoices` shows per-month coverage anchored to bank outflow;
months with thin capture (e.g. Jan) are visibly flagged; GP% is no longer
presented as reliable when coverage is low.

## Done criteria
- `purchases` contains rows with `source` in {`dext`, `portal:*`} in addition to
  `email`; all idempotent.
- Coverage view + `/invoices` coverage signal live; low-coverage months flagged.
- New scrapers paired, scheduled, and emitting debug dumps + alerts on failure.
- Selftest stays green; no cross-realm leakage (Dext/portal imports are `work`).

## Risks / mitigations
- **Dext UI scraping is brittle** — no API, so it's the only route. Resilient
  selectors, `_debug.dump_state` on miss, Telegram alert, and a clear "stale
  Dext capture" freshness check. Scraping Jo's own account/data — no ToS issue.
- **Portal MFA** — handle per-portal as Dojo does (email MFA via google-fetch).
- **Coverage denominator accuracy** — depends on correctly classifying which
  bank outflows are supplier spend; start with a conservative category filter
  and refine. Present coverage as an estimate, not gospel.
- **Scraper scripts must not live only in a writable container layer**
  ([[feedback-bot-responder-scripts-not-baked]]) — bake `dext.py`/portal
  scrapers into the playwright image and rebuild, don't hot-drop.

## Notes / decisions
- Decisions captured: Dext via **Playwright scrape** (not CSV/Xero); portal
  targets **chosen after T2.0 recon**; coverage indicator **in scope**, anchored
  to bank outflow.
- Sequence suggestion: T2.0 recon → Track 3 (fast, high-value honesty) →
  Track 1 (Dext) → Track 2 portals.
