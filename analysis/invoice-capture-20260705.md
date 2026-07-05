# Invoice Capture Gap — Re-measurement (2026-07-05)

Read-mostly recon of `vendor_invoice_inbox` + cross-check against `bank_transactions` and
`xero_bills`. Supersedes the 2026-06-19 finding in `analysis/ytd-recon-2026-06.md`
("~58% capture, 183 no-PDF"). All numbers below were derived fresh today — see queries
inline. `SET app.current_entity='all'` used throughout (read-only, `home_ai.set_realm('owner')`
or `SET app.current_realm='owner'` first).

## 0. Where the old 58% came from

`analysis/ytd-recon-2026-06.md` (2026-06-19): ARTL captured supplier invoices £76,580 (140
rows, dedup by idempotency_key) vs derived cost-of-sales £132,121 (net_cost_all from
`v_daily_cost_vs_sales`, ~152 days) = 58%. Root cause cited: 183/232 `invoice.detected`
events had no PDF attachment. A parallel finding in the same doc: only 3 of those 183
recovered £250 via email-body extraction; conclusion was "structural, not closable by
email-body ingestion." No dedicated script produced the 58% figure — it was computed ad hoc
against `v_daily_cost_vs_sales`; `scripts/u128-email-vs-xero-diff.sh` is a *different* metric
(inbox-vs-Xero orphans, used for the Dext-forward nudge, not for the capture-rate headline).

## 1. Current state — population taxonomy

```sql
SET app.current_entity='all';
-- population basis: received_at (invoice_date is NULL on ~70% of rows independent of
-- capture — a separate, known think:false bug per memory, not this gap)
SELECT COUNT(*) FROM vendor_invoice_inbox
 WHERE received_at >= '2026-01-01' AND received_at < '2027-01-01';   -- 4,249
```

| Slice | Count |
|---|---|
| Total 2026 rows (received_at) | 4,249 (entity 1 = ARTL: 4,231; entity 3 = Personal: 18) |
| `is_statement = true` (excluded — not invoices) | 218 |
| `status = 'duplicate'` (correctly deduped) | 719 |
| `status = 'ignored'` (notifications/marketing/receipts/rejected) | 1,491 |
| **Real invoice candidates** (`status IN (new, extracted, needs_review)`, not statement) | **1,900** |
| — of which `gross_amount > 0` (captured) | **1,012** |
| — of which uncaptured | 888 |

**Current capture rate = 1,012 / 1,900 = 53.3%** (row-count basis, real-candidate
denominator — i.e. after excluding statements/duplicates/correctly-ignored noise, which the
June £-based metric didn't explicitly separate out).

Of the 888 uncaptured candidates (before Phase 2 re-drive):
| Bucket | n | amount_seen stake (£, where extracted) |
|---|---|---|
| No PDF at all (`pdf_local_path IS NULL`) | 787 | 1,445 |
| PDF present, `vision_attempts < 5` (queued, not yet drained) | 66 | — |
| PDF present, `vision_attempts >= 5` (escalation tier) | 26 | 0 |

**Important caveat on £-based comparison to June:** raw `SUM(gross_amount)` for entity 1
2026 (all non-null-amount rows, any status) is £1,292,386 (887 rows by invoice_date) —
this figure is **contaminated** and should not be quoted:
- Jo's personal Gmail auto-re-forwards the Capital on Tap "Your monthly statement is ready"
  email to itself daily, each with one more `Fwd:` prefix (`19f029f6...` →
  `19f2bd25...`, 9 rows in June/July alone, £64,848 recurring in the sum). All are correctly
  flagged `is_statement=true`, so they're excluded from the real-candidate metric above, but
  they inflate any naive `SUM(gross_amount)` query and burn vision/API cycles for zero
  benefit. **Recommend Jo (or a mail rule) kill the auto-forward loop** — not fixed here (no
  new pipeline / mail-rule change authorized).
- The genuine, once-a-month Capital on Tap statement emails (`contact@capitalontap.com`) are
  clean — one row per month, Jan–Jun 2026, correctly `is_statement=true`, correctly excluded.
- £161k of the entity-1 captured total has `category_canonical IS NULL` (mostly this same
  Capital-on-Tap financing noise), and £23k is miscategorised as `income`.

Cleaner £ comparison: captured non-statement invoices in COGS-relevant categories
(wet/dry/cafe) = £157,312 gross YTD vs derived **COGS-proper** (net_wet+net_dry+net_cafe from
`v_daily_cost_vs_sales`) = **£73,330** net over 168 days-with-data. The two aren't directly
comparable (gross vs net, different day-count due to per-site revenue gaps) — flagging as a
**second, separate data-integrity item** (COGS categorisation / gross-vs-net alignment), not
re-derived further here since it's out of this task's scope.

**Bottom line on "the number": row-count capture rate is 53.3%, meaningfully worse than the
June headline suggested if you exclude noise — but the June 58% and today's 53.3% are not
apples-to-apples (different denominators: £-cost-model vs row-count-of-real-candidates).
Recommend the £-based metric be retired in favour of the row-count one until COGS
categorisation (repairs/utilities/software vs wet/dry/cafe) is cleaned up.**

## 2. Phase 2 — re-driving the mechanical fixes

### u125-pdf-attachment-fetch.sh (hourly cron, `invoice_pdf_attach_fetch`, limit 200)
Candidate count against its own WHERE clause today: **0**. The cron is live (`5 * * * *`)
and has already fully drained its intended backlog — this is *not* a bug, it's working as
designed. u125 permanently skips rows once `pdf_fetch_error` is set or
`extraction_method` is classified as unfetchable — so it self-empties once genuinely
no-attachment mail is triaged.

### u284-pdf-fetch-backfill.sh (manual, targets `pdf_low_conf` tier)
Candidates before run: **79**. Ran it (`bash scripts/u284-pdf-fetch-backfill.sh 100`,
~93s, rate-limited 0.4s/row):

```
2026-07-05T18:58:54+01:00 [u284] done: ok=79 fail=0 of 79
```

**79/79 fetched successfully**, 0 failures. Candidate count after: **0**. These rows now
have a local PDF and are queued for the next vision-drain pass (not run here per the
task's instruction not to re-drain escalation tier — these aren't escalation tier, they're
freshly PDF'd `pdf_low_conf` rows that were previously blocked purely on missing bytes).
Effect on the headline capture rate: unchanged for now (53.3%) since extraction hasn't run
yet — expect a small uplift (up to +142 rows queued incl. these 79, £3,532 amount_seen
stake) once the vision drain next processes them.

### Legacy no-PDF population (u49-fetch-invoice-pdfs.sh's original filter, table-wide)
`pdf_fetch_error = 'no pdf attachment'` (set by the retired `u49-fetch-invoice-pdfs.sh`,
2023–2026, 2,916 rows total, mostly `ignored`/`duplicate`) — **166 rows still `status='new'`**
with this error and no local PDF (jo: 141, info: 19, admin: 6). Spot-checked 5 (NatWest
notifications, Worldpay notification, ATS Travel, Amazon) — all genuinely transactional
emails with no PDF attachment. **Classification confirmed correct, no bug.** u49 is not
cron'd (superseded by u125) and was not re-run — its looser retry filter (`pdf_fetch_error IS
NULL OR pdf_fetched_at < now() - interval '1 day'`) would re-attempt 3,339 rows table-wide,
nearly all of which are years-old and already correctly classified; re-running it would burn
API calls for ~0 yield. **Not re-driven — not worth it.**
One row (`account='paperless'`) fails with `404: account 'paperless' not in
static_context.gmail.accounts (active)` — that Gmail integration is dead; single row, not
worth a fix.

### Pre-u291 binary-mode-bug era (dead_letter re-drive)
Checked `dead_letter` table: **0 unresolved rows** for any invoice/document/P2 pipeline.
11,008 already-resolved rows sit in `dead_letter_archive` (matches the "595+ vision-drain
captures" memory note — that backlog was fully drained and archived). **No re-drive path
needed — already done.**

### Escalation tier (vision_attempts >= 5) — counted, NOT re-drained per instruction
**150 rows total** (all-time) with `vision_attempts >= 5` and still no `gross_amount`.
Top vendors:

| Vendor | rows |
|---|---|
| jolyon.sandercock@gmail.com (self-forwards, incl. the statement-loop above) | 24 |
| **J&R Foodservice** `accounts@jrf.lls.com` (kitchen supplier) | 22 |
| Mathew Clapham `berrysmith.com` (professional/legal) | 13 |
| Office Malthouse / Malthouse Team (self, internal admin@/info@malthousetintagel.com) | 5 + 3 |
| lee cornish (personal) | 5 |
| GCSC SW | 3 |
| CIL Enquiries, Cornwall Council | 3 |
| Max Knightley (architect) | 3 |
| jolyon.sandercock@gmail.com (2nd address form) | 3 |

J&R Foodservice is the one commercially meaningful name here — a real, high-volume kitchen
supplier whose invoices are structurally hard to vision-extract (scanned/handwritten
delivery-note-style PDFs per prior notes). Confirmed also as the #1 vendor in
`needs_review` (99 rows, £11,311 + a further 9 rows / £29,539 under a second sender
`Helen Fricker`) and the #1 unlinked-Xero-bill vendor (71 bills, £14,031 — see §3).

## 3. Cross-source completeness (bank vs inbox)

Bank-side counterparty linkage is **still 0/285** for entity-1 2026 spend (confirms prior
note: counterparty resolver is REVIEW-mode live for invoices but still shadow for bank) — so
vendor↔bank matching had to be done by description-substring, not `counterparty_id`. Most
`bank_transactions.category` values for ARTL 2026 non-transfer spend are `needs_review`
(own categorisation gap, not an invoice-capture issue).

Named-vendor bank spend (entity 1, 2026, category not a transfer) vs inbox presence:

| Vendor (bank description match) | Bank £ (2026) | Inbox rows same-vendor 2026 | Verdict |
|---|---:|---:|---|
| Bupa | 378 | **0** | **Gap** — paid via DD, never seen in inbox at all |
| Gulf Westways (fuel) | 136 | 0 | Paper/card, see §4 |
| Motor Fuel Group (fuel) | 54 | 0 | Paper/card, see §4 |
| British Gas | 7,682 | 69 | Captured (attribution via subject, per existing note) |
| Caterbook | 670 | 14 | Captured |
| Cornwall Council (rates) | 2,635 | 23 | Captured |
| Trail | 270 | 8 | Captured |
| Arval (vehicle lease) | 831 | 11 | Captured |
| DesignMyNight | 499 | 11 | Captured |
| NEST Pensions | 2,745 | 5 | Captured |
| Others (Xero, Microsoft, Spotify, O2, giffgaff, BT, Google Workspace, Pennon Water, Starlink, Workforce.com, Clearbrew, Tamar Koffi) | <£1k each | present | Captured (SaaS/DD subscriptions, low £, not COGS-relevant) |

Only **Bupa** stands out as a genuine "paid, never captured" vendor in this bank-side check
— everything else recognisable in bank descriptions already has inbox rows. This confirms
the residual gap is not primarily a bank-vs-email mismatch; it's concentrated in the
inbox-side extraction/no-PDF buckets already quantified in §1–2, plus the true paper/portal
vendors below.

## 4. Residual gap taxonomy (the deliverable)

| Root cause | Evidence | Named vendors |
|---|---|---|
| **(a) Invoice never emailed — paper/portal/fuel-card only** | Zero inbox rows *ever* in 2026 despite confirmed spend (bank and/or Xero) | **Kingfisher Brixham** (fish, £2,685/17 Xero bills, 0 inbox), **Gulf Westways** (fuel, 0 inbox), **Motor Fuel Group** (fuel, 0 inbox), **BP** (fuel, 0 inbox), **Julian Trick Window Cleaning** (trade, 0 inbox), **Partridge Ventilation** (contractor, mostly 0 — 2 stray inbox rows only). **Forest Produce** and **Bidfresh** invoice via the **Podfather** ordering/invoicing portal (`noreply@podfather.com`) — real inbox rows exist (order confirmations) but the £-bearing invoice document itself lives in the portal, not the email; 22+12 rows / £1,445 amount_seen sit un-extractable for this reason. |
| **(b) Emailed to an unwatched address** | Only `jo`, `info`, `admin` (+dead `paperless`, `2972 3187 02`) receive volume; `bot`/`pounana` (named in u125's account allowlist) show ~zero 2026 rows | No hard proof found (would need mailbox-wide search outside these 3 accounts) beyond **Bupa** as the standout candidate — always e-invoices for corporate healthcare cover, zero inbox trace, plausibly landing on an address (e.g. broker/accountant) not currently monitored. Flagging as **unverified — worth a targeted Gmail search**, not confirmed. |
| **(c) Attachment format unsupported** | `non-pdf-attached` extraction_method, 1,059 rows all-time / 257 in the uncaptured-candidate slice | Mostly Amazon (order confirmations, not invoices), Booking.com, and internal Malthouse self-forwards — low commercial value. |
| **(d) Extraction-hard (escalation tier, vision_attempts>=5)** | 150 rows, see §2 table | **J&R Foodservice** (the one that matters — kitchen supplier, £14k+ across needs_review/escalation/unlinked-Xero), Mathew Clapham/berrysmith.com, Max Knightley (architect), GCSC SW |
| **(e) Genuinely no invoice exists (DD/contract, no doc ever generated)** | HMRC NDDS/SDDS, Cornwall Council business rates DD, NatWest Business Loan, card-repayment/inter-entity-transfer bank categories | HMRC, Cornwall Council, NatWest, most GoCardless-DD utility lines — these are bank-only by design, correctly out of scope for an "invoice" pipeline. |

**Overlap note:** Xero/Dext feed revival is explicitly a parallel task (P3 Xero Sync is
PARKED per `STATE.md` — OAuth authorize endpoint rejecting Xero API requests since before
2026-05-18; `xero_bills` here is stale, max `invoice_date` 2026-06-01 / max `ingested_at`
2026-05-18). The reverse-orphan check below (Xero bills with no linked inbox row) is
therefore **already ~5 weeks stale** and should be re-run once that OAuth issue is fixed —
I did **not** touch the Xero/Dext scrapers or OAuth config, per the constraint.

Reverse-orphan check (2026 Xero bills with no `vendor_invoice_inbox.xero_bill_id` link):
231 bills / £30,367 unlinked. Top vendors: J&R Food Services £14,031 (71), West Country Food
Service £6,675 (79), Kingfisher Brixham £2,685 (17), Partridge Ventilation £1,455 (1), St
Austell Brewery £1,237 (2, likely just a linking miss — 62 St Austell rows exist in inbox),
Dojo £1,194 (4). Most of these vendors (J&R, West Country, St Austell) **do** have heavy
inbox volume — so most of this £30k is a **linking gap** (xero_bill_id not being matched),
not a capture gap; the true "never captured at all" subset is the (a) list above.

## 5. Ranked next actions (£ impact, rough order)

1. **J&R Foodservice extraction fix** — highest named £ at stake across three separate
   findings (99 needs_review £11.3k, 9 more £29.5k under a second sender, 22 escalation-tier,
   71 unlinked-Xero £14k). Likely a scanned/low-quality PDF format issue specific to this
   vendor — worth a vendor-specific extraction prompt/template rather than more generic
   vision retries.
2. **Podfather portal ingestion (Forest Produce + Bidfresh)** — a bounded, two-vendor portal
   scrape (or forwarded-order-confirmation-body parse) would close a real, quantified gap
   (£1,445+ seen, likely higher once properly extracted) without touching the Dext/Xero
   OAuth work in flight.
3. **Kill the Capital-on-Tap self-forward loop** — zero £ impact on the real capture metric
   (already excluded via is_statement) but cheap to fix and stops ~1 wasted vision-API call/day
   plus inbox clutter.
4. **Bupa unwatched-address check** — cheap (one targeted Gmail search across broader
   mailboxes) to confirm/deny category (b); £378 stake is trivial but the *pattern* (insurance
   e-invoices going somewhere unmonitored) could apply to other vendors not yet surfaced.
5. **Xero-bill linking pass** (not a capture fix, a matching fix) — £30k of "unlinked" bills
   is mostly J&R/West Country/St Austell rows that already exist in the inbox; a
   fuzzy-match re-pass once Xero OAuth is restored would resolve most of it without new
   ingestion. Do this *after* the Dext/Xero OAuth parallel task lands, since the same data
   source is involved.
6. **Fuel-card / trade receipts (Kingfisher, Gulf Westways, Motor Fuel, Julian Trick,
   Partridge)** — genuinely paper/card-only; only fixable by asking vendors to switch to
   email invoicing, or accepting a manual monthly Dext upload for these five. Low £, low
   priority.
7. **COGS categorisation cleanup** (wet/dry/cafe vs repairs/utilities/software/null) — needed
   before any future £-based capture-rate metric is trustworthy; currently £161k of captured
   2026 invoice value has `category_canonical IS NULL` (mostly Capital on Tap financing,
   correctly excluded from COGS but polluting naive category rollups).

## Scripts touched
- Ran (no code changes): `scripts/u284-pdf-fetch-backfill.sh 100` — 79/79 fetched, 0 failures.
- Read only, no changes made: `scripts/u125-pdf-attachment-fetch.sh`,
  `scripts/u49-fetch-invoice-pdfs.sh`, `scripts/u128-email-vs-xero-diff.sh`,
  `scripts/u68-recon-orchestrator.sh`.
- No bugs found in u125/u284 worth a code fix — both are working as designed; the residual
  gap is data (paper/portal vendors, extraction-hard PDFs), not pipeline defects.
