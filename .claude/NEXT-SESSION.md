# Next session — opening prompt (draft)

_Updated 2026-05-31 (overnight). Read `MASTER.md` + the two specs + plan first._

## ACTIVE PROJECT: Invoice Intelligence (Project A → B)
Specs: `docs/superpowers/specs/2026-05-30-invoice-{intelligence,cogs-analytics}-design.md`
Plan:  `docs/superpowers/plans/2026-05-31-invoice-capture-projectA.md`

**Done + verified (shadow, zero prod impact):**
- Stage 1 — `V206` migration applied: `purchases` + `purchase_lines` + `cogs_category_map`, RLS realm-isolation, indexes, grants, seeded map.
- Stage 2 core — `scripts/projA/ladder.py`: `gate()` + `derive_realm()`, tested 11/11 (`python3 tests/projA/test_gate.py`); `ai_schemas/invoice_extract.schema.json`.

**Resume here (Stage 2 → 4, plan has the task list):**
1. `scripts/projA/ocr.py` — pdfplumber + vision fallback, persist PDF.
2. Ladder tier callers in `ladder.py` — local (Ollama qwen2.5 `format`) → Haiku → Sonnet tool-use against the schema; `run_ladder(row)` orchestration writing `purchases`/`purchase_lines` (idempotent, realm-tagged, gate-gated).
3. `scripts/projA/backfill.py` — bounded 12-mo backfill with a **hard cloud-spend ceiling**; validate on `--limit 25` before scaling. **Why I paused here:** this is the first step that spends cloud $ and needs quality eyeballing — wanted a checkpoint, not a blind paid run.
4. Slugs: `purchases_recent`, `purchases_unverified`, `purchases_by_category` (+ smoke-test).
5. **[HUMAN]** `/invoices/review` UX, per-surface cutover behind flags + parity gate, retire legacy `invoices` — none of this autonomously.

## Other open items (from before)
- **Xero Sync (P3)** not live; **U147** RLS-role connection migration (services still on `postgres` superuser).
- P9 fix validated only on replayed events — confirm next real `document.received` is clean.
- Heartbeat now **6-hourly always-emit** — sanity-check Telegram volume.
- Trail + Dojo scrapers parked (broken/CAPTCHA).
- `booking-scraper.py`/`weather-sync.py` run from bot-responder `/app` writable layer → recreate wipes them.
