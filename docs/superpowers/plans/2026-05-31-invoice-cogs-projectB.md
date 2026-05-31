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

## Caveats baked into the design (don't hide from the UI)
- **Purchase date ≠ consumption** → headline grain is **weekly/monthly**; daily shown but flagged noisy. True stock-adjusted COGS needs inventory counts (out of scope).
- **Capture confidence** travels with every ratio.

## Self-review
- Spec coverage: COGS view (Task 2) ✓, GP (Task 3) ✓, food/drink/prime/vendor/price-creep slugs (Task 4) ✓, category↔sales map (uses V206 `cogs_category_map`) ✓, frontend (Task 5) ✓, caveats ✓, tests (Task 6) ✓. Category-coverage dependency surfaced as prereq Task 1.
- No placeholders in the core SQL (Task 2 full); Tasks 3–6 are task-level with explicit interfaces/columns.
