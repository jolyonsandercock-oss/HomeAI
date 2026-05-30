# Invoice Capture (Project A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:executing-plans to
> implement task-by-task. Steps use `- [ ]` checkboxes. **All work is SHADOW** —
> new tables only, nothing touches the live website until a separate, human-gated
> cutover. Stop and checkpoint at any task tagged **[HUMAN]**.

**Goal:** Capture every supplier invoice into clean, realm-tagged `purchases` /
`purchase_lines` via a local→Haiku→Sonnet→human extraction ladder, with a
12-month backfill — all in shadow, zero production impact.

**Architecture:** Tiered extraction with a cross-field validation gate; reads the
existing ingest staging (`vendor_invoice_inbox`) + persisted PDFs/OCR; writes only
new tables. Cloud spend bounded by tier-0-first + a hard ceiling.

**Tech Stack:** Postgres 16 (migrations `V<N>__`), Python in `homeai-playwright`/
`homeai-bot-responder` (asyncpg + urllib), Ollama (qwen2.5:7b), Anthropic tool-use
(Haiku/Sonnet), pdfplumber + vision-OCR.

---

## File / artifact map

- `postgres/migrations/V<N>__projA_purchases.sql` — new tables + RLS + indexes.
- `scripts/projA/ladder.py` — extraction ladder (tiers + gate + realm). One job.
- `scripts/projA/ocr.py` — PDF→text (pdfplumber; vision fallback). One job.
- `scripts/projA/backfill.py` — bounded 12-mo backfill orchestrator (spend cap).
- `ai_schemas/invoice_extract.schema.json` — header+lines tool-use schema.
- `tests/projA/` — fixtures + gate/ladder/idempotency tests.
- Slugs (DB): `purchases_recent`, `purchases_unverified`, `purchases_by_category`.

---

## Stage 1 — Schema (migrations) [autonomous]

### Task 1: purchases + purchase_lines + cogs_category_map

**Files:** Create `postgres/migrations/V<N>__projA_purchases.sql`

- [ ] **Step 1: Write the migration**

```sql
-- V<N>__projA_purchases.sql  (additive, shadow; no drops)
CREATE TABLE IF NOT EXISTS purchases (
  id                bigserial PRIMARY KEY,
  idempotency_key   text UNIQUE NOT NULL,         -- 'purch:<account>:<gmail_message_id>' | 'purch:scan:<paperless_doc_id>'
  source            text NOT NULL,                -- 'email' | 'scan'
  source_ref        text,                         -- gmail_message_id / paperless_doc_id
  account           text,                         -- info|admin|jo|pounana|bot
  pdf_path          text,
  ocr_text          text,
  vendor_id         bigint,
  vendor_name       text,
  invoice_number    text,
  invoice_date      date,
  due_date          date,
  net_amount        numeric(12,2),
  vat_amount        numeric(12,2),
  gross_amount      numeric(12,2),
  currency          text DEFAULT 'GBP',
  category          text,                         -- canonical purchase category
  is_invoice        boolean,                      -- classifier verdict
  extraction_tier   text,                         -- local|haiku|sonnet|human
  confidence        numeric(4,3),
  gate_passed       boolean DEFAULT false,
  verified          boolean DEFAULT false,
  verified_by       text,
  verified_at       timestamptz,
  entity_id         int,
  realm             text NOT NULL DEFAULT 'work', -- work|personal|owner (derived at ingest)
  created_at        timestamptz DEFAULT now(),
  updated_at        timestamptz DEFAULT now()
);
CREATE TABLE IF NOT EXISTS purchase_lines (
  id                  bigserial PRIMARY KEY,
  purchase_id         bigint NOT NULL REFERENCES purchases(id) ON DELETE CASCADE,
  line_no             int,
  description         text,
  product_canonical_id bigint,
  quantity            numeric(12,3),
  unit                text,
  unit_price          numeric(12,4),
  line_net            numeric(12,2),
  vat_rate            numeric(5,2),
  category            text
);
CREATE TABLE IF NOT EXISTS cogs_category_map (
  purchase_category text PRIMARY KEY,             -- 'food','drink_alcohol','drink_soft','packaging',...
  sales_department  text,                         -- maps to touchoffice department, e.g. 'FOOD SALES'
  is_cogs           boolean DEFAULT true          -- false for non-COGS (utilities, services, capex)
);
CREATE INDEX IF NOT EXISTS idx_purchases_date     ON purchases(invoice_date);
CREATE INDEX IF NOT EXISTS idx_purchases_realm    ON purchases(realm);
CREATE INDEX IF NOT EXISTS idx_purchases_unverif  ON purchases(verified) WHERE verified=false;
CREATE INDEX IF NOT EXISTS idx_plines_purchase    ON purchase_lines(purchase_id);
-- RLS: realm_isolation + entity_isolation, mirroring existing domain tables (V65 pattern).
ALTER TABLE purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchase_lines ENABLE ROW LEVEL SECURITY;
-- (policies copied from the established realm_isolation/entity_isolation templates)
```

- [ ] **Step 2: Apply** — `docker exec -i homeai-postgres psql -U postgres -d homeai < postgres/migrations/V<N>__projA_purchases.sql`
- [ ] **Step 3: Verify** — tables exist, RLS on, indexes present (`\d purchases`).
- [ ] **Step 4: Seed `cogs_category_map`** with the obvious rows (food→FOOD SALES, drink_alcohol→ALCOHOL SALES, drink_soft→'SOFT DRINKS', packaging→non-COGS, etc.).
- [ ] **Step 5: Commit.**

### Task 2: tool-use extraction schema

- [ ] Create `ai_schemas/invoice_extract.schema.json` — object with `is_invoice`,
  `vendor_name`, `invoice_number`, `invoice_date`, `due_date`, `net`, `vat`, `gross`,
  `currency`, `category`, `confidence`, and `lines[]` (`description, quantity, unit,
  unit_price, line_net, vat_rate, category`). Required: `is_invoice, confidence`.
- [ ] Commit.

## Stage 2 — Extraction ladder [autonomous]

### Task 3: OCR module (`scripts/projA/ocr.py`)
- [ ] Test: a known text-PDF fixture → non-empty text; an image-only fixture → vision path returns text.
- [ ] Implement: pdfplumber first; if text < 50 chars, vision-OCR fallback (reuse the mortgage-statement vision path). Persist PDF to `/home_ai/storage/invoices/YYYY/MM/`.
- [ ] Commit.

### Task 4: validation gate (`scripts/projA/ladder.py::gate()`)
- [ ] Test: `{net:80,vat:16,gross:96, lines sum 80}` → pass; mismatch → fail; missing required → fail; non-invoice → fail.
- [ ] Implement: net+vat==gross (±0.02), Σ line_net==net (±tol), required fields present, invoice_date sane, vendor non-empty, is_invoice true.
- [ ] Commit.

### Task 5: realm derivation (`ladder.py::derive_realm(account, entity_id)`)
- [ ] Test: info/admin→work; jo/pounana→personal; bot→owner; entity 1→work, 3→personal.
- [ ] Implement per SPEC §2.5 mapping. Commit.

### Task 6: tier callers + escalation (`ladder.py`)
- [ ] Test (mocked model responses): tier-0 high-confidence+gate-pass → accept at local; tier-0 fail → escalate to haiku; haiku fail → sonnet; sonnet fail/new-vendor → mark for human (no write to verified).
- [ ] Implement: `extract_tier(text, tier)` (Ollama format / Anthropic tool-use against the schema); `run_ladder(row)` loops tiers until gate+confidence pass or exhausted; writes `purchases`+`purchase_lines` with `extraction_tier`, `confidence`, `gate_passed`, `verified=false`; realm tagged. Idempotent on `idempotency_key`.
- [ ] Commit.

## Stage 3 — Backfill (bounded) [autonomous, capped]

### Task 7: backfill orchestrator (`scripts/projA/backfill.py`)
- [ ] Test: dry-run lists candidates from last 365d (`vendor_invoice_inbox`, hex gmail ids), respects `--limit` and `--max-cloud-spend`.
- [ ] Implement: iterate last-12-month invoices oldest→newest through `run_ladder`; **hard spend ceiling** (track Haiku/Sonnet tokens via ai_usage; abort cloud escalation when ceiling hit, leave remainder at tier-0/human). Start `--limit 25` to validate, then scale.
- [ ] Run sample (25), inspect quality, then run the rest in background with the ceiling. Commit.

## Stage 4 — Query surface (shadow) [autonomous]

### Task 8: purchases slugs
- [ ] Insert `purchases_recent`, `purchases_unverified`, `purchases_by_category` into `query_whitelist` (realm=`work`, `approved_at=NOW()`); smoke-test via `scripts/test-all-slugs.cjs`.
- [ ] Commit.

## Stage 5 — Verify queue + cutover [HUMAN — do NOT do autonomously]

### Task 9 [HUMAN]: `/invoices/review` UI — build proposal only; Jo reviews UX before ship.
### Task 10 [HUMAN]: per-surface cutover (repoint `frontend_invoices_recent` etc. to `purchases` behind a flag, parity gate first) — Jo approves each.
### Task 11 [HUMAN]: retire legacy `invoices` — only after all surfaces flipped + stable.

---

## Overnight execution order (autonomous, safe)
Stages 1→4 only. Stop before Stage 5. Long backfill runs in background under the
spend ceiling. Morning report: tables, row counts, tier distribution, spend, test
results, and the Stage-5 items queued for Jo.

## Self-review
- Spec coverage: ladder (§3 A) ✓, storage/realm (§2,§4 A) ✓, backfill (§7 A) ✓,
  verify+cutover (§5,§7b A) ✓ tagged HUMAN, COGS (B) → separate plan. 
- No placeholders in Stage 1 (full DDL); Stages 2–4 are task-level with test intent +
  interfaces (code elaborated at execution per-task, TDD).
- Types consistent: `purchases`/`purchase_lines` columns referenced uniformly.
