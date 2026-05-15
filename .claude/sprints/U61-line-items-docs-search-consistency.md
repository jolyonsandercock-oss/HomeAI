# U61 — Line items + docs + search + date consistency + backfill

**Status:** shipped 2026-05-15 (remote, autonomous). All 7 tracks landed.

## What landed

### T0 — Model bench-off
- 5 representative invoices, 32 hand-curated truth lines.
- qwen2.5:7b: **78.1 %** (51 s) — local, free, choked on Cornwall Cooling service lines.
- Haiku 4.5: **96.9 %** (13 s, ~£0.005/inv) — chosen primary.
- Sonnet 4.6: **100 %** (25 s, ~£0.05/inv) — reserved as confidence-fallback.
- Full results: `/home_ai/logs/u61-bench-results.md`.

### T1 — V76, `product_canonical` + line-item extractor
- V76 adds `product_canonical` + `product_alias` (gin_trgm_ops for fuzzy matching), 24 new seed rows on top of the pre-existing 68 (ice-cream flavours, RBS-mastercard-visible products, service rows).
- `v_invoice_lines_resolved` view joins lines→canonical.
- `/home_ai/scripts/u61-line-items-extract.sh` — Haiku primary, validation against invoice total (≤ £0.05 or 1 %), Sonnet rescue on fail.
- **145 / 145 invoices extracted, 729 line items, total cost £0.34** (2 invoices needed Sonnet rescue).
- Side-effect fix: `/api/invoice/{id}/pdf` now falls back to `/home_ai/data/invoice-pdfs/{id}.pdf` when `first_attachment_path` is NULL (it was for every invoice).

### T2 — Invoice detail panel
- `/api/invoices/{id}/lines` — joined to canonical.
- `/api/invoices/{id}/preview-image` — page-1 PNG (default 1200px), cached at `/home_ai/storage/invoice-previews/`.
- `pdfplumber-service` extended with `/render-page1-png`.
- `PUT /api/invoices/{id}/notes` — append-only ledger format: `[YYYY-MM-DD jo] <text>`. Stored in the existing `vendor_invoice_inbox.notes` column.
- Row-level 🔍 button on `/invoices` opens a side panel with PDF preview, line items table (Tabulator), and notes textarea with Save.
- V76b adds `top_purchases_window` slug to query_whitelist — enables NL questions like "how much milk did I buy in the last 60 days" via the finance ask box.

### T3 — V77, email FTS
- `emails.tsv` STORED tsvector (subject=A, sender=B, body=C) + GIN index. 473 rows indexed in 0.7 s.
- `/api/emails/search?q=&account=&from_date=&to_date=&limit=` returns rank-ordered rows with `ts_headline` snippet (yellow `<mark>` highlighting).
- `/search` page — text box, account chip-strip, date-range, Tabulator with click-through to `/viewer/email/{account}/{message_id}`.
- Falls back to trigram ILIKE for partial-string queries (sort codes, account numbers).

### T4 — V78, documents OCR + entity linking
- V78 extends `documents` with `paperless_id`, `file_path`, `mime_type`, `sha256` (unique), `ocr_text` + STORED `ocr_tsv`, `linked_table`, `linked_id`, `linked_by`, `uploaded_by`. Entity_id now nullable (filled by linker).
- `v_documents_linked` view joins linked docs to their target's label.
- `POST /api/documents/upload` — multipart upload, OCR via existing pdfplumber service, file stored at `/home_ai/storage/documents/<sha256>.<ext>`. Auto-link logic:
  - **plate regex** `[A-Z]{2}\d{2}\s?[A-Z]{3}` → `vehicles.registration`
  - **postcode** → `properties.postcode_full`
  - **child name** → `children.name`
- `/documents` page — drag-and-drop + click-to-choose, real-time feedback chip showing linked-to-X, Tabulator below for every stored doc.
- Verified: uploaded a minimal PDF containing `"WF14 FNP"` → auto-linked to vehicle id 2 (Seat Alhambra).
- **Paperless-ngx container is U62 work**. Scanner-to-folder ingest is in `/home_ai/.claude/sprints/U62-*.md` (queued).

### T5 — Date-picker consistency
- Shared `dateWindow` Alpine component (was already used by caterbook/invoices/workforce) now emits a `days` integer in the `date-window-changed` event payload.
- Backfilled onto `touchoffice.html`, `economics.html`, `dojo.html`, `finance.html`. All 8 chart pages share identical preset row: Today / Yesterday / This wk / Last wk / MTD / Last mo / 30d / 90d / custom range. Per-page localStorage persistence.
- Finance tabs that accept a window (`interest_paid_window`, `fees_paid_window`, `spend_by_category_window`, `monthly_finance_costs`) auto-adapt `days` vs `months` based on the picker.

### T6 — V79, feed coverage audit + backfill
- V79 adds `feed_coverage` table (UNIQUE feed_name+expected_date) + `v_feed_coverage_summary` + `v_feed_coverage_recent_gaps` views.
- `/home_ai/scripts/u61-coverage-audit.sh` (cron daily 04:30) — walks 2 years × 12 feeds, classifies each (feed, date) as ok / missing / partial / stale. Excludes legitimate-closure days for sporadic feeds (vendor_invoices / caterbook / bank_*).
- Audit baseline: 8,772 rows. 100 % ok on 7 feeds (caterbook, vendor_invoices, all bank accounts). Low ok % on workforce_shifts (17 %), dojo (7/12 %), touchoffice (33/45 %) — mostly legitimate business-closure days.
- `/home_ai/scripts/u61-backfill-orchestrator.sh` identifies **301 real-miss targets** (days where one site has data but the partner doesn't, or workforce missing while sales rolled). Currently logs targets only; the actual range-scrape script for TouchOffice is U62 follow-on.
- `/api/coverage/summary` + `/api/coverage/recent-gaps` endpoints power a future Mission Control tile.

## Mission Control ribbon
Added 3 new links: **Finance →** (U60), **Search →** (T3), **Documents →** (T4) — all emerald-bold, alongside Economics.

## Carry-forward to U62
1. **TouchOffice range-scraper** (`u27-touchoffice-scrape-date.sh`). 301 known-miss dates waiting.
2. **Paperless-ngx container** bring-up (stretch §3.13). Schema is ready; just needs the SMB → consume folder → REST API loop.
3. **Recipe model** — sales-to-consumption reconciliation now that line items exist.
4. **Product alias auto-population**: only ~13 % of lines auto-matched a canonical product. Spin up a periodic Sonnet pass that suggests canonical_id+alias for unmatched descriptions, with Jo's approval.
5. **Business-calendar table** so the coverage audit can mark genuine closure days as `closed` not `missing`.
6. **Image OCR**: T4 OCRs PDFs only. Image OCR (TIFF/JPEG/PNG) needs either Paperless-ngx or a tesseract sidecar — queued.

## Migrations applied this sprint
- V76 — `product_canonical`, `product_alias`, `v_invoice_lines_resolved`
- V76b — `top_purchases_window` slug
- V77 — `emails.tsv` + GIN
- V78 — `documents` extensions, `v_documents_linked`
- V79 — `feed_coverage` + summary views

## Scripts added
- `/home_ai/scripts/u61-line-item-bench.sh`
- `/home_ai/scripts/u61-line-items-extract.sh`
- `/home_ai/scripts/u61-coverage-audit.sh` (cron 30 4 * * *)
- `/home_ai/scripts/u61-backfill-orchestrator.sh`

## Infra changes
- `build-dashboard` gained two read-write mounts: `/home_ai/storage/documents` and `/home_ai/storage/invoice-previews`. The `/home_ai/data/invoice-pdfs` mount (added pre-T1) is read-only.
