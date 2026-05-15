# U49 — Invoice line-item intelligence

**Prereqs**: U47a (vendor_invoice_inbox.site) shipped. `vendor_invoice_lines` table exists since V41 but has 0 rows.

**Remote-doable**: 100%.

**Goal**: extract every line item from every invoice so Jo can ask "how much milk did we buy last month" / "are we using more wine than usual" / "what's our YTD spend on cleaning products". v1 is inventory + trend. Consumption-vs-sales reconciliation (recipe model) is deferred to U50.

## Tracks

### Track 0 — Local-vs-Haiku-vs-Sonnet bench-off (~30m)

Before committing to a model, A/B/C 5 representative invoices.

**Sample**: 5 invoices spanning vendor types — typical line-table layouts.

**Models**:
1. **qwen2.5:7b local** with our U7-optimised prompt + JSON schema constraint (`format` param). Cost £0.
2. **Haiku 4.5** tool-use with `input_schema`. ~£0.005/invoice.
3. **Sonnet 4.6** tool-use with `input_schema`. ~£0.05/invoice.

**Scoring**: against a hand-curated truth set for the 5 samples — % of lines correctly parsed (description + qty + unit_price + line_total).

**Decision rule**:
- qwen ≥ 90% → use qwen for the 145-invoice backfill (£0).
- 70–89% → Haiku (£1.50 backfill, acceptable accuracy).
- < 70% → Sonnet (£8 backfill, premium accuracy).

Output: `/home_ai/logs/u49-bench-results.md` showing the picks.

### Track 1 — Product canonical schema (~1h, V58)

```sql
CREATE TABLE product_canonical (
  id              BIGSERIAL PRIMARY KEY,
  family          TEXT NOT NULL,         -- 'milk','wine','beer','spirits','meat','fish','veg','dairy','packaging','cleaning','fuel','condiments','sundry'
  name            TEXT NOT NULL,         -- 'Whole milk 4L'
  default_unit    TEXT,                  -- 'L','kg','bottle','case','each'
  default_size    NUMERIC,
  default_size_unit TEXT,
  notes           TEXT,
  created_at      TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE product_aliases (
  id              BIGSERIAL PRIMARY KEY,
  canonical_id    BIGINT REFERENCES product_canonical(id),
  raw_text        TEXT NOT NULL,         -- 'CRAVENDALE WHOLE MILK 6X1L'
  vendor_name     TEXT,                  -- 'Westcountry Wines' etc.
  confidence      NUMERIC(3,2),          -- AI-suggested vs Jo-confirmed
  confirmed_by    TEXT,                  -- 'ai' | 'jo'
  created_at      TIMESTAMPTZ DEFAULT now(),
  UNIQUE (raw_text, vendor_name)
);

-- Extend vendor_invoice_lines with canonical_id
ALTER TABLE vendor_invoice_lines
  ADD COLUMN canonical_id BIGINT REFERENCES product_canonical(id),
  ADD COLUMN qty_canonical NUMERIC,     -- normalised to default_unit (e.g. 6×1L → 6.0 if default_unit='L')
  ADD COLUMN extracted_by TEXT,         -- 'qwen' | 'haiku' | 'sonnet'
  ADD COLUMN extraction_confidence NUMERIC(3,2);
```

**Seed product_canonical**: ~30 rows covering common families.

### Track 2 — Line-item extractor (~2h)

Per Track 0 winner, build the extractor.

**Script `u49-extract-invoice-lines.sh <invoice_id>`**:
- Reads PDF path from `vendor_invoice_inbox.first_attachment_path`.
- Pipes through pdfplumber (already-running service) → text.
- Sends text + vendor name + invoice total to the chosen model.
- Tool-use returns `[{line_no, description, qty, unit, unit_price, line_total, suggested_family}]`.
- Validates: sum of line_total within 5% of invoice net_amount (otherwise flag for review).
- INSERTs into `vendor_invoice_lines`. Idempotent on `(invoice_id, line_no)`.

**Trigger**: extend `u36-invoice-haiku-fallback.sh` to call line-extractor after header extraction succeeds.

### Track 3 — Backfill 145 invoices (~30-60m)

`u49-backfill-lines.sh`:
- Iterates `vendor_invoice_inbox WHERE is_statement=false AND status NOT IN ('duplicate','ignored') AND id NOT IN (SELECT DISTINCT invoice_id FROM vendor_invoice_lines)`.
- Cost cap: stop at £15 spent on Sonnet or 200 invoices, whichever first.
- Telegram progress every 25 invoices.
- Logs to `/home_ai/logs/u49-backfill.log`.

Run in background (~30-60 min).

### Track 4 — Alias matcher (~1h)

Per new line item:
1. Lookup `product_aliases WHERE raw_text = NEW.description AND vendor_name = NEW.vendor`.
2. If hit → use existing `canonical_id`.
3. If miss → Haiku asks "Best match for 'CRAVENDALE WHOLE MILK 6X1L' (vendor=Westcountry) among existing canonicals?" with a short list of `product_canonical WHERE family='milk'`. Returns `canonical_id` or "new family suggestion".
4. INSERT into `product_aliases` with `confidence` from Haiku.

Manual UI on a new `/products` page:
- List unmatched lines (`canonical_id IS NULL`).
- One-click "Merge into X" / "New canonical".
- Bulk reassign by raw_text pattern.

### Track 5 — Query UI (~1h)

**Search on `/invoices`**: type `milk` → filter line items + show totals row "X lines · £Y net · Zsum_qty units" across vendors.

**New page `/products`**:
- Family selector dropdown.
- Per family: trend chart (last 90d weekly qty + £), vendor mix pie, this-month-vs-last-month variance.
- Click-through to source invoices.

**Endpoint `/api/products/family?family=milk&date_from=...&date_to=...`** returns:
```json
{
  "family": "milk",
  "items": [{"date": "...", "vendor": "...", "qty": 4, "unit": "L",
              "unit_price": 1.20, "line_total": 4.80,
              "invoice_id": 123, "canonical_name": "Whole milk 4L"}],
  "totals": {"qty_canonical": 240, "net": 312.45, "lines": 18},
  "by_vendor": [...],
  "by_week": [...]
}
```

### Track 6 — Docs + memory (~30m)

- SPEC.md §7.13 line-item intelligence.
- STATUS.md U49 wrap.
- STRETCH.md tick line-item asks.
- Memory: project_homeai.md add U49 summary + V58 to migration list.

## Total ~6h

## Anti-scope

- **No consumption-vs-sales reconciliation** (recipe model) — U50.
- **No supplier price tracking** ("our milk price went up 8% last month, switch vendor") — could be added as a v1.5 widget later, easy once data is in.
- **No barcode/SKU lookup against external database** — out of scope; Jo's canonicals are the source of truth.

## Risks

1. **Local model accuracy on tabular data**: qwen2.5:7b may struggle with line-table parsing. Track 0 bench-off determines this; if it fails we use Haiku as the cheap fallback.
2. **Vendor invoice formats vary wildly**: some are clean tables, some are dense text. Sum-validation rule (lines sum ≈ net total) catches the worst extraction failures and flags them.
3. **Sonnet backfill cost**: cap at £15 to prevent surprise spend. Telegram digest of final cost.
