# U61 execution plan

## Context

U61 sprint plan exists at `/home_ai/.claude/sprints/U61-line-items-docs-search-consistency.md`. T0 (model bench-off) is complete — Haiku 4.5 won at 96.9% on 5 representative invoices, Sonnet 4.6 reserved as fallback. V76 (product_canonical + product_alias + v_invoice_lines_resolved) is applied; 92 seed products including the 8 ice-cream flavours and the products visible in the bench invoices.

The extractor script `u61-line-items-extract.sh` is written but failed on first run with 404s — the extractor inside `homeai-bot-responder` calls the dashboard's `/api/invoice/{id}/pdf` endpoint, which looks up `vendor_invoice_inbox.first_attachment_path`. For all 5 bench invoices that column is NULL, even though the actual PDFs do exist at `/home_ai/data/invoice-pdfs/{id}.pdf`.

This plan covers the immediate unblock plus the remaining 5 tracks of U61.

## Immediate unblock (T1 fix)

**Problem**: `vendor_invoice_inbox.first_attachment_path` is NULL for the 5 bench invoices (and likely for many of the 145 that have `has_pdf=true`). The dashboard's existing `GET /api/invoice/{id}/pdf` (`main.py:1555`) returns 404 in that case. The extractor can't fetch the PDF bytes.

**Why fix it via path-correction not bind-mount**: the PDFs are already in `/home_ai/data/invoice-pdfs/{id}.pdf` (one file per invoice id, 145 files). The existing dashboard endpoint already validates path-traversal against `_INVOICE_STORAGE_ROOT` (`main.py:1570`). The cleanest fix is to (a) point `first_attachment_path` at the real on-disk path, OR (b) teach the dashboard endpoint to fall back to `/home_ai/data/invoice-pdfs/{id}.pdf` when `first_attachment_path` is NULL. Option (b) is one-line and doesn't require a backfill — recommended.

**Files to change**:
- `/home_ai/services/build-dashboard/main.py` — add a fallback in `api_invoice_pdf` at line 1567-1568. If `path` is NULL but `/home_ai/data/invoice-pdfs/{id}.pdf` exists, serve that.

**Acceptance**: `curl -H "X-Realm: owner" http://100.104.82.53:8090/api/invoice/142/pdf` returns the PDF bytes (200 + 136897 bytes for invoice 142).

## T1 — extractor backfill (rest of)

**Run** `u61-line-items-extract.sh` against all 145 invoices once the unblock is in. Verify the 5 bench invoices first, then unbounded.

**Acceptance**:
- ≥ 140 of 145 invoices have ≥ 1 row in `vendor_invoice_lines`.
- ≥ 80% of `vendor_invoice_lines` rows have non-NULL `canonical_id` (trigram match against product_canonical, threshold 0.45 already in the script).
- `SELECT COUNT(*) FROM vendor_invoice_lines WHERE extraction_confidence < 0.85;` reveals the rows that need Jo's review.
- Total cost ≤ £2 (Haiku pass + occasional Sonnet rescue).

## T2 — invoice page enhancements

**Files**:
- `/home_ai/services/build-dashboard/main.py` — add 3 endpoints near the existing `/api/invoice/{id}/pdf` (line 1555):
  - `GET /api/invoices/{id}/lines` — read `v_invoice_lines_resolved`.
  - `GET /api/invoices/{id}/preview-image` — return a 1200px PNG of page 1, cached on disk under `/home_ai/storage/invoice-previews/{sha256}.png`. Use pdfplumber service for the underlying render, OR `pdfplumber.Page.to_image()` if we keep extraction inside the service. Simpler: extend `homeai-pdfplumber` `main.py` with a `/render-page1-png` route.
  - `PUT /api/invoices/{id}/notes` — body `{"notes":"..."}`. Appends `[YYYY-MM-DD username] <text>\n` to existing `vendor_invoice_inbox.notes` (column already exists). Returns the new note string.
- `/home_ai/services/build-dashboard/static/invoices.html` — row-click handler opens a side panel rendering the preview PNG + a Tabulator of line items + textarea for notes with a Save button.
- V77a (~5 line migration) seeds `query_whitelist` with `top_purchases_window` → `SELECT canonical_family, SUM(line_net) FROM v_invoice_lines_resolved WHERE invoice_date >= CURRENT_DATE - :days * INTERVAL '1 day' GROUP BY 1 ORDER BY 2 DESC LIMIT :limit;` so the NL ask box can answer "how much milk last month".

**Acceptance**:
- Click any extracted invoice on `/invoices` → preview + line items render in < 1s.
- Add a note, refresh, note persists with `[YYYY-MM-DD jo]` prefix.
- `curl /api/finance/ask -d '{"question":"how much milk did I buy in the last 60 days"}'` returns a £ figure with `top_purchases_window` as the selected tool.

## T3 — email full-text search (V77)

**Files**:
- New migration `V77__emails_fts.sql` — `ALTER TABLE emails ADD COLUMN tsv tsvector GENERATED ALWAYS AS (...) STORED;` plus a GIN index. Uses `setweight()` to rank subject (A) > from (B) > body (C).
- `/home_ai/services/build-dashboard/main.py` — `GET /api/emails/search?q=&account=&from=&to=&limit=50`. Uses `websearch_to_tsquery('english', q)`, ranks with `ts_rank_cd`, returns `ts_headline` for the snippet.
- `/home_ai/services/build-dashboard/static/search.html` — new page: single text box, account multi-select, dateWindow component (shared), Tabulator below with click-through to `/viewer/email/{account}/{message_id}` (already exists at `main.py:1980`).
- `index.html` ribbon — add `<a href="/search" ...>Search →</a>` next to Finance.

**Acceptance**:
- `curl /api/emails/search?q=MAL125` returns ≥ 1 row from `info@malthousetintagel.com`.
- Searching a literal sort code (`6000-49011170`) finds matching emails.
- Index build < 10s on the 461 existing rows.

## T4 — Paperless-ngx + scanner ingest (V78)

**Files**:
- `/home_ai/docker-compose.yml` — new `paperless` service block (image pinned per [[feedback_dashboard_image_rebuild]]), with `paperless_consume`, `paperless_media`, `paperless_data` volumes. Postgres on existing homeai-postgres with a new `paperless` DB; redis on existing homeai-redis. Network `ai-internal` + `ai-services`. Tailscale-only port `100.104.82.53:8011`.
- Vault: write `secret/paperless` (api_token, db_password, secret_key) via `vault kv put` — script in `/home_ai/scripts/u61-paperless-bootstrap.sh`.
- New migration `V78__documents_paperless.sql` — adds `paperless_id`, `file_path`, `ocr_text`, `linked_table`, `linked_id`, plus FTS GIN on `ocr_text` and `(linked_table, linked_id)` index.
- `/home_ai/scripts/u61-paperless-sync.sh` (cron `*/15`) — pulls new docs from Paperless REST API since last `paperless_id`, inserts `documents` rows, runs entity-linking heuristics: plate regex (`[A-Z]{2}\d{2}\s?[A-Z]{3}`) → `vehicles.registration`; postcode → `properties.postcode_full`; child name → `children.full_name`.
- `/home_ai/services/build-dashboard/main.py` — `GET /api/documents/by-link/{table}/{id}` + `/documents` page.

**In-person (Jo)**: Brother ADS-2800W "AI BATCH" profile → SMB to `\\<jolybox-tailscale>\paperless-consume`. ~30 min.

**Acceptance**:
- One test batch of 3 docs lands in `documents` with `ocr_text` populated.
- A scanned MOT cert with a vehicle plate auto-links to the vehicle row.
- `/documents` page lists everything with entity-link filter.

## T5 — date-picker consistency

**Files**:
- Audit: caterbook, invoices, workforce already on shared `dateWindow`. Touchoffice, economics, dojo, finance, /m all use ad-hoc selectors.
- `/home_ai/services/build-dashboard/static/js/datewindow.js` (if it exists; otherwise inline component in pages) — confirm preset buttons: Today, Yesterday, This wk, Last wk, This mo, Last mo, 30d, 90d, 1y, custom range. The U47b memory notes say these already exist.
- Update each page to `<div x-data="dateWindow('<key>')">` and wire `@date-window-changed.window` handler.
- For `finance.html` tabs — pass `days=` / `months=` from the picker into the slug call.

**Acceptance**: pick "Last month" on /invoices, click into /finance — the finance tabs respect the same window. All pages show identical preset row in same order.

## T6 — feed coverage audit + 2y backfill (V79)

**Files**:
- New migration `V79__feed_coverage.sql` — table `feed_coverage(feed_name, expected_date, row_count, last_scraped, status, notes, realm)` + status check + index on missing.
- `/home_ai/scripts/u61-coverage-audit.sh` (cron daily 04:30) — walks every (feed, date) in last 2 years, marks ok/missing/partial/stale, emits `coverage_gap` event for new missing rows.
- `/home_ai/scripts/u61-backfill-orchestrator.sh` (one-shot) — re-runs scrapers per missing date. Rate-limited 1 req/s per source. Logs to `audit_log` with `event_type='backfill_run'`. Sources: touchoffice (Playwright already supports historical), caterbook (email pull), workforce (Tanda date-range), dojo (API), invoices (re-parse PDFs we have).
- Mission Control widget on `index.html` — "Coverage gaps" tile, top 5 missing.

**Acceptance**:
- `feed_coverage` has a row for every (feed, date) in last 2y.
- First backfill run drops `missing` count by ≥ 90%.
- Daily cron writes new rows; new gaps fire Telegram via `telegram_outbox`.

## Verification sequence (end-to-end)

1. After T1 unblock: `INVOICE_IDS="142 152 166 168 220" /home_ai/scripts/u61-line-items-extract.sh` → 5 invoices extract cleanly.
2. After T1 backfill: `SELECT COUNT(*) FROM vendor_invoice_lines;` ≥ 600 (5 bench × ~6 lines + ~140 more × ~5 lines).
3. After T2: click invoice on `/invoices`, see preview + lines + note save.
4. After T3: `/search` finds "MAL125".
5. After T4: scan test batch lands in `/documents` with plate-linking working.
6. After T5: date window respected across `/invoices` → `/finance` flow.
7. After T6: `SELECT feed_name, COUNT(*) FROM feed_coverage WHERE status='missing' GROUP BY 1;` shows < 10% gap rate.

## Critical files referenced

- `/home_ai/.claude/sprints/U61-line-items-docs-search-consistency.md` (sprint scope)
- `/home_ai/logs/u61-bench-results.md` (model decision)
- `/home_ai/scripts/u61-line-items-extract.sh` (extractor, ready to run after unblock)
- `/home_ai/scripts/u61-line-item-bench.sh` (bench harness, kept for re-running)
- `/home_ai/postgres/migrations/V76__product_canonical.sql` (applied)
- `/home_ai/services/build-dashboard/main.py:1555` (api_invoice_pdf — needs fallback)
- `/home_ai/services/build-dashboard/static/invoices.html` (T2 UI)
- `/home_ai/services/pdfplumber/main.py` (extend for /render-page1-png)
