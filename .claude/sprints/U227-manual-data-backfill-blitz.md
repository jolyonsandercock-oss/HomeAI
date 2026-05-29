# U227 — Manual data backfill blitz

**Realm:** mixed — bank/card backfills span work + personal; mortgage statements are PERSONAL (per realm split, ARE in PERSONAL); dojo + work bank accounts are WORK. Each task notes its realm.

**Trigger:** 2026-05-29 manual-data freshness audit (u35-upload-tasks-email) surfaced 15 stale upload items. Worst offenders:
- NatWest current accounts 16–543d behind reconciliation
- 5 RBS Mastercard statements 153–671d behind
- 3 Principality mortgage statements 149–424d behind
- Dojo CSVs 8d behind (separate fix in U229)

**Status:** queued.

**Why it matters:** without backfills, the dashboard's "work cash position" and personal net-worth views are stale by months in places; reconciliation is the limiting factor on closing the books per quarter, and Principality mortgage 295905-02 cross-collateralises Olde Malthouse + Salutations so its statements drive ARE & personal mortgage coverage at the same time.

---

## T1 — Bank current account catch-up (WORK + PERSONAL)

Six NatWest current accounts behind 16–543d. Priority order = age × business impact:

- [ ] **ATR Trading current** (work, 39d) — Dojo settlement account, blocks revenue close
- [ ] **AREL current** (personal, 17d) — Atlantic Road Estate ops
- [ ] **Jo main personal current** (personal, 16d)
- [ ] **Joint Account** (personal, 31d)
- [ ] **Jo personal #2** (personal, 29d)
- [ ] **Jo personal #3 / #4** (personal, 512d / 543d) — multi-year reconciliation, scope separately if time-boxed
- [ ] **Tax Reserve — ATR savings** (work, 1920d) — explicitly low-activity; decide whether to add an `ignore` flag instead of backfilling

For each: download statement (PDF or CSV) from NatWest online → Paperless → tag with bank account. Existing bank-statement pipeline parses period_start/end + transactions into `bank_transactions` keyed by `idempotency_key`.

**Acceptance:** `MAX(transaction_date)` per account within last 14d (current) or `ignore_flag=true`.

## T2 — Credit card statement catch-up (PERSONAL)

5 RBS Mastercards 153–671d behind. Per memory `project-credit-cards`: V73 schema (`card_statements` + `account_transfers`), 71 PDFs + 477 CSV txns + 269 paired transfers as of U59.

- [ ] **RBS Mastercard ****2621** (153d) — Jo personal #1
- [ ] **RBS Mastercard ****3092** (372d) — Jo personal #2, active
- [ ] **RBS Mastercard ****9799** (671d, predecessor of 2621) — review whether still owed any backfill
- [ ] **RBS Mastercard ****8864** (390d, dormant) — flag `ignore` rather than backfill

Per-statement: PDF → Paperless tag `card-statement` + account ref → existing pipeline parses period_end + opening/closing/spend totals + spawns paired-transfer detection.

**Acceptance:** `MAX(period_end)` per active card within last 40d.

## T3 — Mortgage statement catch-up (PERSONAL)

3 Principality mortgages 149–424d behind. Per memory `project-properties-mortgages`: 295905-02 cross-collateralises Olde Malthouse + Salutations; per memory `feedback-mortgage-scans-camscanner-ocr`, 7 prior PDFs are image-only — Tesseract picks up only "CamScanner" watermark, so they need vision-OCR (U151b path).

- [ ] **295905-02** (149d, work) — Olde Malthouse + Salutations cross-collateral; highest dashboard impact
- [ ] **967003-10** (424d, personal)
- [ ] **967002-01** (424d, personal)

Per-mortgage: download letter PDF from Principality Commercial → Paperless tag `mortgage-statement` + account_ref. Pipeline routes image-only pages to vision-OCR (U151b) for `mortgage_statement_periods` insert.

**Acceptance:** `MAX(period_end)` per account within last 40d.

## T4 — Surface manual-data widget on /app home

The 08:00 Telegram fires once a day; the morning email is a checklist; neither is visible mid-day when Jo's actually on /app. Add a widget so the gap is glanceable.

- [ ] New slug `manual_data_pending_uploads` returning the same shape as `u35-upload-tasks-email` SQL (or wrap that SQL in a view).
- [ ] Frontend tile on Mission Control (right column, beneath the existing dashboard refactor tiles per memory `project-dashboard-refactor`) — count + worst offender + age.
- [ ] Click-through → full list page.

## T5 — `ignore_flag` on accounts

Dormant / predecessor accounts shouldn't keep appearing on the upload list forever. Add a soft-ignore so the freshness query naturally filters them.

- [ ] Migration: `ALTER TABLE bank_accounts ADD COLUMN exclude_from_freshness boolean NOT NULL DEFAULT false`
- [ ] Same on `mortgage_accounts` (defaulted to false; closed_date already covers most)
- [ ] Update `u35-manual-data-freshness.sh` + email script to filter on it instead of name-matching `dormant` / `predecessor`
- [ ] Set true for: RBS ****8864 (dormant), RBS ****9799 (predecessor), Tax Reserve ATR savings (decide), Jo personal #3/#4 (decide)

## T6 — Verify

- [ ] Re-run `python3 /home_ai/scripts/u35-upload-tasks-email.py` → 0 stale rows (or only newly-stale ones)
- [ ] `data_source_freshness` slug shows `bank current` / `card` / `mortgage` all `ok`
- [ ] Mission Control widget shows `0 pending` or only fresh-warn items

---

## Deferred / out of scope

- **Bank-statement OCR/parsing for image-only scans** — already handled via the U151b vision-OCR pipeline; flag through that pipeline, no new work here.
- **Tax-reserve account fully-historical** — 1920d is over 5 years; decide whether to mark ignore or do a separate "open-statement archive" sprint.
- **Dojo backfill** — handled by U229 (script is broken, separate fix).
- **NatWest CSV-feed automation** — Open Banking integration would remove the manual step entirely, but it's a much bigger sprint; record as future U.
