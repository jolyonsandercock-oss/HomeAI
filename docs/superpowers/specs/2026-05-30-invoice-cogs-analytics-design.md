# Invoice Intelligence — Design Spec (Project B: COGS & ratio analytics)

**Date:** 2026-05-30
**Status:** Design — awaiting user review
**Depends on:** Project A (`purchases` + `purchase_lines`, categorised + realm-tagged).
**Realm:** `work` (entity 1). Personal purchases captured by A but excluded from COGS.

---

## 1. Goal

Turn clean purchase data into the COGS + ratio picture for the pub/café:
- **Cost of goods** by category (food / drink / packaging / …) per day / week / month.
- **Gross margin %** = (sales − COGS) ÷ sales, by site and category.
- **Food cost %** and **drink cost %** (category COGS ÷ matching sales).
- **COGS-to-sales ratio**, **labour-vs-COGS**, **prime cost** (COGS + labour ÷ sales).
- **Vendor concentration** (spend share) and **price-creep** (unit-price drift per product).
- **Theoretical vs actual** food cost variance (recipe cost vs purchased cost), where
  `recipes`/`recipe_components` data exists.

## 2. Inputs (all existing once A ships)

| Source | Provides |
|---|---|
| `purchase_lines` (A) | categorised line spend, `product_canonical_id`, qty, unit price |
| `epos_daily_reports` | daily sales (net/gross) by site/entity |
| `touchoffice_department_sales` | sales split by department (food/drink/...) |
| `v_daily_labour_by_team` | labour cost (for prime cost / labour-vs-COGS) |
| `recipes` / `recipe_components` | theoretical dish cost (variance analysis) |
| `product_canonical` | product identity across vendors (price-creep) |

## 3. Components (views + slugs, isolated)

- **`v_cogs_daily`** — `purchase_lines` → daily category COGS (work realm). Purchase
  date basis; note invoices ≠ consumption (see §5 caveat).
- **`v_gross_margin`** — joins COGS to sales (department mapping food/drink) → GP% by
  category/period.
- **Slugs** (realm=`work`, approved): `cogs_by_category`, `gross_margin_30d`,
  `food_drink_cost_pct`, `prime_cost_ratio`, `vendor_concentration`,
  `product_price_creep`, `recipe_cost_variance`.
- **Frontend** — COGS panels (new `/cogs` page or a section on `/sales`/`/admin`):
  GP% trend, category cost stack, top price-movers, vendor share, prime-cost gauge.
  Built with existing components (`Section`, charts, `PlaceholderState`).

## 4. Category ↔ sales mapping

The one piece of real modelling: map purchase categories to the sales departments
they generate, so cost % is meaningful — e.g. `food purchases ÷ FOOD SALES`,
`drink/alcohol purchases ÷ ALCOHOL SALES`. Maintained as a small mapping table
(`cogs_category_map`) so it's explicit and editable, not hard-coded.

## 5. Caveats (state, don't hide)

- **Purchase date ≠ consumption date.** Invoice-based COGS is lumpy (you buy in
  batches). Daily GP% will be noisy; **weekly/monthly is the honest grain** for
  ratios. Stock-adjusted COGS would need inventory counts (out of scope — flag for
  later if Jo wants true periodic COGS).
- **Coverage matters.** A ratio is only as good as A's capture completeness; surface
  a "% of spend captured/verified" confidence indicator beside the headline ratios.

## 6. Testing

- View unit tests on a seeded `purchase_lines` fixture (known category totals → known
  GP%). Mapping-table tests. Slug smoke-test (the existing harness). Reconciliation:
  `Σ category COGS` ties to `Σ purchase_lines.line_net`.

## 7. Decisions / open

- Headline grain = **weekly + monthly** (daily shown but flagged noisy).
- Stock/inventory-adjusted COGS = **out of scope** (needs counts); revisit later.
- `/cogs` page vs `/sales` section — decide at build (lean: a `/sales` section first).
