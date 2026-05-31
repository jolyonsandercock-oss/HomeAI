# Invoice COGS & Ratios (Project B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps
> use `- [ ]`. Builds on Project A's populated `purchase_lines` (work realm). All
> read-side (views + slugs + one frontend section) — no writes to source data.

**Goal:** Turn `purchase_lines` + sales + labour into COGS and ratio analytics
(GP%, food/drink cost %, prime cost, vendor concentration, price-creep) at an
honest weekly/monthly grain, surfaced on the dashboard.

**Architecture:** Postgres views over `purchase_lines` joined to
`touchoffice_department_sales`/`epos_daily_reports` and `v_daily_labour_by_team`
via the existing `cogs_category_map`; exposed as `query_whitelist` slugs (realm
`work`); a `/sales` COGS section consumes them.

**Tech Stack:** Postgres 16 views + migration `V<N>__`; slugs in `query_whitelist`;
Next.js frontend (`app/sales/page.tsx`), recharts.

---

## Pre-flight (data-quality dependency — read first)
Project A captured 613 invoices but **category is NULL on ~43%** and only
purchases where `gate_passed AND is_invoice` are trustworthy. Therefore:
- Every COGS view filters `WHERE gate_passed AND is_invoice AND realm='work'`.
- Every headline ratio is paired with a **capture-confidence** number
  (% of work spend that is categorised + verified) so a thin denominator is visible,
  never hidden. **Do Task 1 (category backfill) before trusting the ratios.**

## File / artifact map
- `postgres/migrations/V<N>__projB_cogs_views.sql` — views (no new tables; `cogs_category_map` already exists from V206).
- Slugs (DB rows): `cogs_by_category`, `gross_margin_period`, `food_drink_cost_pct`, `prime_cost_ratio`, `vendor_concentration`, `product_price_creep`, `cogs_capture_confidence`.
- `services/homeai-frontend/app/sales/page.tsx` — add a "Cost of goods" `<Section>`.
- `tests/projB/` — view fixtures + reconciliation.

---

## Task 1: Strengthen category coverage (prereq) [autonomous]
**Files:** new `scripts/projA/categorise.py`
- [ ] Test: a purchase with NULL category + a known vendor in `vendor_category_rules` → gets the mapped category.
- [ ] Implement: for `purchases` where `category IS NULL AND gate_passed`, assign category from `vendor_category_rules` (vendor→category); fall back to a cheap Haiku classify on `vendor_name`+top line descriptions; write back `purchases.category` + `purchase_lines.category`. Idempotent; spend-capped.
- [ ] Run; confirm NULL-category share drops materially. Commit.

## Task 2: COGS period view [autonomous]
**Files:** `postgres/migrations/V<N>__projB_cogs_views.sql`
- [ ] **Write `v_cogs_period`:**
```sql
CREATE OR REPLACE VIEW v_cogs_period AS
SELECT date_trunc('week', p.invoice_date)::date AS week,
       date_trunc('month', p.invoice_date)::date AS month,
       COALESCE(pl.category, p.category, 'other') AS category,
       m.sales_department, m.is_cogs,
       sum(pl.line_net) AS cogs_net
FROM purchases p
JOIN purchase_lines pl ON pl.purchase_id = p.id
LEFT JOIN cogs_category_map m ON m.purchase_category = COALESCE(pl.category, p.category)
WHERE p.gate_passed AND p.is_invoice AND p.realm = 'work' AND p.invoice_date IS NOT NULL
GROUP BY 1,2,3,4,5;
```
- [ ] Apply migration; verify `SELECT * FROM v_cogs_period ORDER BY week DESC LIMIT 5`. Commit.

## Task 3: Gross-margin view (COGS ↔ sales) [autonomous]
- [ ] **Write `v_gross_margin_period`** — join `v_cogs_period` (is_cogs categories) to `touchoffice_department_sales` summed to the same week/month via `sales_department`; compute `gp_pct = (sales - cogs)/NULLIF(sales,0)`. Weekly + monthly rows.
- [ ] Verify against a hand-checked week. Commit.

## Task 4: Ratio slugs [autonomous]
For each: insert into `query_whitelist` (realm `work`, `approved_at=NOW()`), then smoke-test with `scripts/test-all-slugs.cjs`.
- [ ] `cogs_by_category` — category COGS, weekly + monthly (params: grain, range).
- [ ] `gross_margin_period` — GP% by category/period from `v_gross_margin_period`.
- [ ] `food_drink_cost_pct` — food COGS ÷ FOOD SALES, drink COGS ÷ ALCOHOL SALES.
- [ ] `prime_cost_ratio` — (COGS + labour from `v_daily_labour_by_team`) ÷ sales.
- [ ] `vendor_concentration` — vendor spend share over a window.
- [ ] `product_price_creep` — `product_canonical_id` unit-price trend (first vs latest).
- [ ] `cogs_capture_confidence` — % of work invoices that are gate-passed + categorised (the denominator-health indicator).
- [ ] Commit after each passes the smoke-test.

## Task 5: Frontend — `/sales` "Cost of goods" section [HUMAN review of UX]
- [ ] Add a `<Section title="Cost of goods (weekly)">` to `app/sales/page.tsx` using `useSlug`: GP% trend line, category-COGS stacked bars, top price-movers, vendor-share, prime-cost gauge, and a small **capture-confidence** badge. Reuse existing chart components + `PlaceholderState`.
- [ ] `npx tsc --noEmit`; build + recreate frontend; verify panels render.
- [ ] **[HUMAN]** Jo eyeballs the rendered section before it's considered done.

## Task 6: Tests + reconciliation [autonomous]
- [ ] Seed a `purchase_lines` fixture with known category totals → assert `v_cogs_period` totals and a known GP%.
- [ ] Reconciliation test: `Σ v_cogs_period.cogs_net` ties to `Σ purchase_lines.line_net` (work, gate-passed).
- [ ] Slug smoke-test green. Commit.

---

## §S — Searchability (added requirement)
Spend must be searchable by **vendor** (Forest Produce), **department** (bar,
overhead), **line item / product** (Guinness), and **business & property** (entity
1 vs AREL properties) — across **three surfaces that all read one flat view**:
(a) local model, (b) slugs/queries, (c) frontend table filters.

### Task S1: dimensions — department + product + property [autonomous]
- [ ] Add `department` to `cogs_category_map` and seed: `drink_alcohol→bar`,
  `drink_soft→bar`, `food→kitchen`, `packaging/cleaning/utilities/services/repairs/capex→overhead`,
  accommodation categories→`accommodation`. (`ALTER TABLE cogs_category_map ADD COLUMN department text;`)
- [ ] **Product canonicalisation** (`scripts/projA/canonicalise_lines.py`): for
  `purchase_lines.product_canonical_id IS NULL`, match `description` to
  `product_canonical`/`product_aliases` (normalised exact → trigram fuzzy → cheap
  Haiku for the long tail); create canonical rows for genuinely new products.
  Test: a "Guinness Draught 11G" line resolves to the canonical "Guinness". Idempotent, spend-capped.
- [ ] **Property linkage**: `ALTER TABLE purchases ADD COLUMN property_id bigint;`
  backfill from `account_property_map` (vendor_domain/account_number → property_id);
  business invoices (entity 1, no property) stay NULL. Commit.

### Task S2: flat search view `v_purchase_search` [autonomous]
- [ ] One row per line item, every dimension denormalised for filtering:
```sql
CREATE OR REPLACE VIEW v_purchase_search AS
SELECT p.id AS purchase_id, pl.id AS line_id, p.invoice_date,
       p.vendor_name, p.vendor_id,
       COALESCE(pl.category, p.category) AS category,
       m.department,
       pl.product_canonical_id, pc.canonical_name AS product,
       pl.description, pl.quantity, pl.unit, pl.unit_price, pl.line_net,
       p.entity_id, p.realm, p.property_id, p.gross_amount AS invoice_gross,
       p.gate_passed, p.verified
FROM purchases p
JOIN purchase_lines pl ON pl.purchase_id = p.id
LEFT JOIN cogs_category_map m ON m.purchase_category = COALESCE(pl.category, p.category)
LEFT JOIN product_canonical pc ON pc.id = pl.product_canonical_id
WHERE p.is_invoice;   -- realm RLS still applies on the base tables
```
- [ ] Verify free-text + dimension filters return sensibly (Forest Produce; department=bar; product ILIKE 'guinness'). Commit.

### Task S3: faceted search slug [autonomous]
- [ ] `purchase_search` slug over `v_purchase_search` with **optional** params
  `vendor, department, category, product, entity_id, property_id, date_from, date_to,
  q` (free text over description/vendor/product) — returns matching lines **plus a
  total `sum(line_net)`** so "amount and spend by X" is answered in one call.
- [ ] `purchase_spend_summary` slug — grouped totals by a `group_by` param
  (vendor | department | product | entity | property) for the same filters.
- [ ] Smoke-test both (`scripts/test-all-slugs.cjs`). Commit.

### Task S4: frontend filterable table [HUMAN review of UX]
- [ ] `/sales` (or new `/purchases`) Tabulator-style table over `purchase_search`
  with **column filters + free-text box** on vendor / department / product /
  description / entity / date / amount, and a live filtered-total footer. Reuse the
  existing filterable-table pattern (e.g. the daily sales table). **[HUMAN] Jo eyeballs.**

### Task S5: local-model access [autonomous]
- [ ] The bot/local model answers spend questions by calling `purchase_search` /
  `purchase_spend_summary` (realm `work`, so already loadable by the bot's slug set).
  Add a one-line heuristic to `heuristics.md`: "spend questions (by vendor/department/
  product) → call purchase_spend_summary with the extracted filter." Verify qwen can
  map "how much on Guinness last month" → `{product:'Guinness', group_by:'product', date_from:…}`.
- [ ] Commit.

## Caveats baked into the design (don't hide from the UI)
- **Purchase date ≠ consumption** → headline grain is **weekly/monthly**; daily shown but flagged noisy. True stock-adjusted COGS needs inventory counts (out of scope).
- **Capture confidence** travels with every ratio.

## Self-review
- Spec coverage: COGS view (Task 2) ✓, GP (Task 3) ✓, food/drink/prime/vendor/price-creep slugs (Task 4) ✓, category↔sales map (uses V206 `cogs_category_map`) ✓, frontend (Task 5) ✓, caveats ✓, tests (Task 6) ✓. Category-coverage dependency surfaced as prereq Task 1.
- No placeholders in the core SQL (Task 2 full); Tasks 3–6 are task-level with explicit interfaces/columns.
