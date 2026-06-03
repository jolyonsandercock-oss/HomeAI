# System Hardening & Invoice Pipeline Assessment
**Date:** June 3, 2026 | **Author:** Hermes | **Reviewer:** Claude

---

## Part A: Code Review — Security, Performance, Robustness

### A1 — Critical: Auth on Write Endpoints

**3 API routes with SQL writes and zero authentication:**

| Endpoint | SQL Calls | Risk |
|---|---|---|
| `/api/breakfast/submit` | 4 writes | Public guest form — token validation only, no server auth |
| `/api/dinner/remind` | 1 write | Triggers email sends to guests |
| `/api/feedback/line` | 2 writes | Writes vendor categorisation rules |

**Fix:** Wrap each in a `validateAdminToken()` middleware that checks a Vault-stored HMAC shared secret. The frontend passes this as `Authorization: Bearer <token>`. For the breakfast form (public), the existing signed-token validation suffices but needs expiry enforcement.

### A2 — High: Missing Indexes Causing Full Table Scans

| Table | Seq Scans | Index Scans | Seq % |
|---|---|---|---|
| `entities` | 284K | 126 | 100% |
| `ai_usage` | 195K | 20 | 100% |
| `quota_allocations` | 49K | 1 | 100% |
| `chat_hub_messages` | 45K | 0 | 100% |
| `static_context` | 131K | 0 | 100% |

**Fix:** `entities` needs an index on `realm` (every policy check filters by realm). `ai_usage` needs `(entity_id, timestamp)`. `static_context` appears to be a cache with 131K rows and zero reads — evaluate if it can be truncated or TTL'd.

### A3 — Medium: emails table at 637MB, no Full-Text Search

Search is done via `ILIKE '%term%'` forcing sequential scans. The `email_search` slug we built yesterday does exactly this.

**Fix:** Add a `tsvector` column with a GIN index, populate via trigger, use `plainto_tsquery` in the slug. This is a one-hour fix that makes email search 50-100x faster.

### A4 — Medium: Realm Isolation is Inconsistent

`bank_accounts` policy was patched ad-hoc ("allow personal in work context"). Tables without realm isolation: `snag_inbox`, `query_whitelist`, `vendor_category_rules`, `card_statements`, `email_priority_keywords`.

**Fix:** Apply consistent realm isolation to all tables that hold multi-entity data. Use the `home_ai.entity_isolation()` function pattern already established on `ai_usage`.

### A5 — Low: No CSP Headers, No Rate Limiting

The Next.js config has zero security headers. The app serves to the internet via Tailscale.

**Fix:** Add `next.config.js` headers section with basic CSP, X-Frame-Options, and X-Content-Type-Options. Add a simple in-memory rate limiter to write endpoints (10 req/minute per IP).

### A6 — Robustness: Slug Engine is Fragile

200+ active slugs with no validation at insert time. Broken column references (we've hit: `full_name`, `team`, `shift_cost`) cause cryptic runtime errors instead of failing at approval time.

**Fix:** Add a `validate_slug()` function that runs `EXPLAIN SELECT ...` against the template at `approved_at` time. Reject slugs that fail to plan.

### A7 — Robustness: No Cron Health Monitoring

24 cron entries, no dashboard. The TouchOffice backfill silently stalled for weeks.

**Fix:** Add a `/health/cron` endpoint that checks each cron's last-run timestamp against its expected schedule. Surface on the backend page. Alert if any cron is >2x its interval late.

### A8 — Performance: Frontend Bundle at 113KB Main Chunk

No code splitting by page. The full framework loads for every route.

**Fix:** Use Next.js `dynamic(() => import(...))` for heavy page components. The sales chart, tasks expense table, and rooms view are good candidates.

---

## Part B: Invoice Extraction Pipeline Assessment

### B1 — Existing Infrastructure Inventory

**Already in the repo:**

| Component | Path | Status |
|---|---|---|
| Ollama (GPU inference) | `homeai-ollama` container, qwen2.5:7b at 67 tok/s, 100% GPU | Running |
| LiteLLM proxy | Not found — using direct Ollama API | N/A |
| Playwright scraper | `/home_ai/services/playwright/` — TouchOffice + Caterbook PDF scraping | Running |
| IMAP email ingestion | `homeai-google-fetch` — fetches from 5 accounts | Running |
| n8n workflows | `/home_ai/.claude/n8n-exports/` — gmail-ingest, caterbook-bookings, dead-letter-sweeper | Exported |
| Invoice tables | `vendor_invoice_inbox` (2,561 rows), `vendor_invoice_lines` (21,820 rows) | Live |
| Vendor categorisation | `vendor_category_rules` — domain-based, regex matching, auto-rule creation via triggers | Live |
| Idempotency pattern | SHA-256 hash keys, `ON CONFLICT DO NOTHING` — used in 170 migrations | Established |
| PDF extraction | `pdftotext` on JolyBox, `PyMuPDF` in playwright container, `marker-pdf` available | Available |
| Xero integration | `u128-email-vs-xero-diff.sh` — Xero comparison exists | Partial |
| Dext integration | Not found in repo | Gap |
| Qdrant vector DB | Not found in running containers | Not deployed |

### B2 — Gap Analysis

**What the proposal adds that doesn't exist:**
- Presidio redaction for cloud-bound data
- Tesseract OCR for scanned PDFs (pdftotext/PyMuPDF handle native PDFs, but scans need OCR)
- LLM classification + extraction steps (currently done via regex + manual review)
- LLM cross-check (deterministic validation exists in some scripts, no LLM cross-check)
- Qdrant vector embedding — not currently deployed
- Structured confidence gating

**What already exists that the proposal duplicates:**
- IMAP ingestion + SHA-256 dedupe at file level — already handled by google-fetch + `vendor_invoice_inbox.idempotency_key`
- PDF text extraction — already done in the Caterbook pipeline and the RBS PDF import
- Deterministic arithmetic checks — partially in `u128-email-vs-xero-diff.sh`
- Idempotency at row level — established pattern with SHA-256 keys

### B3 — Model Strategy Verdict

**Hardware constraint:** RTX 3060, 12GB VRAM. phi4:14b at Q4 fits fully on GPU (~9GB). Anything larger spills to CPU.

**Volume:** Tens per month. At this volume, model load/unload cost matters more than per-inference speed.

**Verdict: Single GPU-resident workhorse + rare CPU escalation is correct.**

The cascade (7b→14b→70b) adds complexity with no benefit at this volume:
- Loading 70b into RAM takes ~30-60 seconds per invocation
- 70b on CPU runs at ~2-4 tok/s — a single invoice extraction takes 3-5 minutes
- phi4:14b on GPU runs at ~30-40 tok/s — extraction in 15-30 seconds
- At tens/month, you save ~10 minutes total per month with the cascade vs single model. Not worth the code complexity.

**Recommendation:** phi4:14b handles steps 3+4+6 at ~30-40 tok/s, all on GPU. For the rare review queue (step 8b), escalate to Claude API (already plumbed) rather than running llama3.3:70b locally. Claude API is faster, more accurate, and avoids the 30-60 second 70b load cost.

### B4 — Idempotency Review

The proposal has 3 layers:
1. **File hash (SHA-256)** — matches the existing `idempotency_key` pattern in `vendor_invoice_inbox`
2. **Inv-no + supplier** — this is new. Need to ensure the composite key includes `source_email_id` or `file_hash` to prevent collisions across re-imports
3. **Row-level** — matches existing `ON CONFLICT (idempotency_key) DO NOTHING` pattern

**Gap:** Layer 2 needs to be `(supplier, inv_no, source_file_hash)` not just `(supplier, inv_no)` — otherwise a corrected re-import of the same invoice would be silently dropped.

### B5 — Over-Engineering Flags

| Component | Verdict | Reason |
|---|---|---|
| Qdrant vector DB | **Over-engineered** | For tens of invoices/month, Postgres full-text search with pgvector is sufficient. Qdrant adds a new service to maintain. |
| Presidio redaction | **Over-engineered** | No cloud routing exists yet. Add only when a cloud branch is built. |
| 3-model cascade | **Over-engineered** | Single phi4:14b + Claude escalation handles the volume. |
| n8n orchestration | **Risky** | n8n works for email pipelines but adds a dependency. Direct cron + Python scripts (existing pattern) is simpler for batch processing. |

**Build rule violation:** The proposal's Docker/GPU orchestration needs to go through `start.sh` for Vault env vars. Any new service (Qdrant, Tesseract container) must be added to `docker-compose.yml` and `start.sh`.

### B6 — Recommended Minimal First Build

**Phase 1 (derisk): PDF text extraction + deterministic validation**

Build a single Python script (`u162-invoice-extract.py`) that:
1. Watches `vendor_invoice_inbox` for rows with `extraction_method IS NULL`
2. Runs pdftotext/PyMuPDF on the attached PDF (already cached)
3. Does regex-based extraction of supplier, inv-no, dates, amounts
4. Runs deterministic checks (arithmetic, VAT rate, supplier exists)
5. Writes results to `vendor_invoice_lines`
6. Cron: every 30 minutes

This derisks the pipeline because it works without any LLM dependency. All the infrastructure exists. If the regex extraction is good enough for 80% of invoices, you've already won.

**Phase 2 (add LLM): LLM extraction + cross-check**

Once Phase 1 is running, add phi4:14b for the 20% of invoices that regex can't handle, plus the LLM cross-check step. This is a small addition to the Phase 1 script — just POST to Ollama with a JSON schema format parameter.

**Phase 3 (add review queue): Human review for low-confidence**

Only now add the Claude escalation path for invoices that fail both regex and phi4 extraction.

**Why this order:** Phase 1 gives you a working pipeline immediately with zero new dependencies. Phase 2 adds LLM only where needed. Phase 3 adds the expensive escalation path only for genuine failures. Each phase can be validated independently.

---

## Part C: Priority Action Items

| Priority | Item | Effort | Impact |
|---|---|---|---|
| 🔴 P0 | Auth on 3 write API endpoints | 2h | Security |
| 🔴 P0 | Index on `entities.realm`, `ai_usage(entity_id, timestamp)` | 30m | Performance |
| 🟡 P1 | tsvector + GIN index on `emails.body_text` | 1h | Performance |
| 🟡 P1 | Realm isolation on `snag_inbox`, `vendor_category_rules` | 2h | Security |
| 🟡 P1 | Slug validation at insert time | 1h | Robustness |
| 🟢 P2 | CSP headers + rate limiting | 1h | Security |
| 🟢 P2 | Cron health dashboard | 2h | Robustness |
| 🟢 P2 | Phase 1 invoice extraction (PDF→regex extraction) | 3h | New capability |
| 🟢 P3 | Frontend code splitting | 2h | Performance |
| ⚪ P4 | `static_context` cleanup/TTL | 30m | Housekeeping |

---

*Pass to Claude for review. No code changes requested yet.*
