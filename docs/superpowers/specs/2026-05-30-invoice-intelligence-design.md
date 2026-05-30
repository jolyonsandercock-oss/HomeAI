# Invoice Intelligence — Design Spec (Project A: bulletproof capture)

**Date:** 2026-05-30
**Status:** Design — awaiting user review
**Scope:** Project A only (capture + classify + extract). Project B (COGS & ratio
analytics) is a separate downstream spec that consumes this output.

---

## 1. Goal & success criteria

Pull and classify **every** work-realm supplier invoice with:
- **No false positives** — nothing counts as a purchase until it is either (a)
  schema-valid + cross-checked + high-confidence, or (b) human-verified.
- **No missing fields** — header *and* line items complete, or the invoice is
  escalated until they are.
- **COGS-ready** — per-line product / qty / unit-price / category, so Project B
  can compute GP%, food/drink cost %, vendor concentration, price-creep.

**Definition of done (A):** the verify queue runs at a small steady trickle;
`purchases` + `purchase_lines` are the single source of truth; 12 months of
history backfilled; every required field on a `verified` row is non-null and
cross-checks pass.

## 2. Scope

- **Realm:** work only (entity 1 — pub / café / ice-cream). Personal/AREL excluded.
- **Sources:** supplier emails to `info@` / `admin@` (via existing google-fetch +
  u95 harvest), and Brother→Paperless scans. (Dext is review-only, no API — out.)
- **In scope:** PDF persistence, OCR, header + line-item extraction, vendor +
  category classification, the verify queue, the learning loop, 12-month backfill.
- **Out of scope (Project B):** ratio/COGS analytics, dashboards, Xero push.

## 3. Architecture — the extraction ladder

Each invoice climbs only as far as needed; stops at the first tier returning a
**schema-valid, cross-checked, high-confidence** result.

```
OCR text ─▶ Tier 0  local (Ollama qwen2.5:7b, schema tool-use / `format`)
              │  fail gate / low confidence
              ▼
           Tier 1  Haiku (Anthropic tool-use, input_schema)
              │  fail gate / low confidence / disagreement
              ▼
           Tier 2  Sonnet (tool-use)
              │  still uncertain / new vendor / unresolved
              ▼
           Tier 3  HUMAN verify queue   (authoritative)
```

**Validation gate (run at every tier — the false-positive / missing-field guard):**
- `net + vat == gross` (± £0.02)
- `Σ purchase_lines.line_net == net` (± tolerance)
- all required header fields present + types valid; invoice_date sane
- vendor resolves to a known vendor (else → new-vendor escalation)
- document actually *is* an invoice (vs statement/notification/receipt) — a
  classification step before extraction; non-invoices are marked and excluded.

Accept = gate passes **and** confidence ≥ tier threshold. Else escalate.
`extraction_tier` + `confidence` recorded on every row for observability.

**Components (isolated, independently testable):**
| Component | Does | Depends on |
|---|---|---|
| `ingest` | harvest emails/scans → staging row + persisted PDF | google-fetch, Paperless |
| `ocr` | PDF → text (pdfplumber; vision-OCR for image-only) | pdfplumber, vision model |
| `classify` | is-invoice? + vendor + category | local LLM, vendor rules |
| `extract` (per tier) | OCR text → header+lines JSON (schema-constrained) | Ollama / Anthropic |
| `validate` | cross-field gate; decide accept/escalate | — |
| `verify-queue` | human confirm/correct UI | frontend |
| `learn` | gold labels → rules + fine-tune dataset | purchases, Unsloth |

## 4. Storage

- **PDF persistence:** every invoice saved to `/home_ai/storage/invoices/YYYY/MM/`;
  OCR text stored on the row (re-runs never re-fetch from Gmail).
- **Canonical tables (new):**
  - `purchases` (header): `id, source, source_ref, pdf_path, ocr_text, vendor_id,
    vendor_name, invoice_number, invoice_date, due_date, net_amount, vat_amount,
    gross_amount, currency, category, extraction_tier, confidence, verified,
    verified_by, verified_at, entity_id, realm, idempotency_key, created_at`.
  - `purchase_lines`: `id, purchase_id, line_no, description, product_canonical_id,
    quantity, unit, unit_price, line_net, vat_rate, category`.
- `vendor_invoice_inbox` → demoted to **ingest staging** only (harvest landing zone;
  the ladder reads from it, writes to `purchases`).
- Legacy empty `invoices` table → **retired** (migration drops or archives it; audit
  consumers first per AGENTS rule 7).
- New slugs: `purchases_recent`, `purchases_by_category`, `purchases_unverified`
  (verify-queue feed), realm=`work`, approved.

## 5. Verify queue

- `/invoices/review` — PDF preview beside extracted header+lines; one-tap
  **confirm** or inline **correct**; **mobile-friendly** (Karl on a phone).
- Only Tier-3 items appear (low-confidence / new-vendor / gate-fail).
- On confirm/correct: row → `verified=true`; the diff is captured as a gold label.

## 6. Learning loop ("bake in")

Each verification feeds two paths:
- **Rules (immediate):** per-vendor field hints, `vendor_category_rules`,
  `product_canonical` aliases — next invoice from that vendor auto-resolves lower
  on the ladder (escalation rate falls).
- **Local LLM (periodic):** once ≥ N verified gold rows accrue, **Unsloth QLoRA**
  fine-tune of the Tier-0 model (qwen2.5:7b) → GGUF → Ollama → it handles more
  itself. Re-train on a cadence as new vendors/formats appear. This is the
  previously-deferred Unsloth role, now data-backed.

## 7. Backfill

Re-run the ladder over the **last 12 months** of harvested invoices to populate
`purchases`/`purchase_lines` retroactively (seasonality + YoY for COGS). Bounded
run to cap one-off cloud-escalation cost; Tier-0-first keeps most of it local.

## 8. Testing

- **Fixtures:** a labelled set of real invoices per vendor (header+lines) as the
  extraction gold set; assert field-completeness + cross-checks per tier.
- **Gate unit tests:** net/vat/gross + line-sum tolerances; is-invoice classifier
  on a mix of invoices/statements/notifications (false-positive guard).
- **Idempotency:** re-running ingest/extract on the same invoice is a no-op.
- **Verify→learn:** a correction updates rules and appears in the fine-tune dataset.

## 9. Decisions made (this brainstorm)

- Accuracy model: **hybrid + verify queue** (auto-accept high-confidence, human
  verify the rest).
- Engine: **tiered ladder local→Haiku→Sonnet→human**, schema-constrained throughout.
- Data model: **new `purchases` + `purchase_lines`**; inbox→staging; retire `invoices`.
- Backfill: **last 12 months**.
- Local fine-tune (Unsloth) is **Phase 2**, gated on the gold set the queue builds.

## 10. Open / deferred

- Exact confidence thresholds per tier — tune during build against fixtures.
- `N` gold rows before first fine-tune — set once label flow is live.
- Project B (COGS/ratios, Xero push) — separate spec after A ships.
