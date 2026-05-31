# Next session — opening prompt (draft)

_Updated 2026-05-31 (overnight). Read `MASTER.md` first._

## ACTIVE: Invoice Intelligence — A done, B search layer done
Specs/plans in `docs/superpowers/{specs,plans}/2026-05-3*-invoice-*`.

**Done + verified (all shadow):**
- **Project A capture** — `ladder.py` (OCR + local→Haiku→Sonnet→human, vision fallback).
  **613 invoices, 3,411 line items, £226k captured**, 74 personal-realm. Run cost ≈ **$3.73**.
- **Project B searchable layer** — V207 views (`v_purchase_search`, `v_cogs_period`,
  `v_gross_margin_period`) + V208 slugs (`purchase_search`, `purchase_spend_summary`,
  `gross_margin_period`, `cogs_capture_confidence`). **Verified searchable by vendor /
  department / line-item / business+property** via the API; bot heuristic added.

**Resume here:**
1. **[HUMAN] Frontend filter table** — the visual table-filter surface (Tabulator-style
   on `purchase_search`) + the `/sales` COGS section (GP% / category / vendor / price-creep
   panels). Plan tasks S4 + Task 5. Needs Jo's eyeball.
2. **Quality (lifts everything):** category backfill (currently **55.8% categorised** →
   `vendor_category_rules` + Haiku) and **product/vendor canonicalisation** (collapse
   "Guinness"/"Forest Produce" name variants → cleaner aggregation + truer GP%). Plan S1 + Task 1.
3. **GP% caveat:** gross-margin reads high (95–100%) *because* COGS is undercounted while
   categorisation is partial — fixing #2 firms it up. `cogs_capture_confidence` surfaces this.
4. Diagnose the **252 unreadable PDFs** (don't render to text or image — likely not valid PDFs).
5. Verify qwen actually maps "spend on Guinness" → `purchase_spend_summary` (heuristic added, untested).

## Other open items
- Xero Sync (P3) not live; U147 RLS-role connection migration (services on `postgres` superuser).
- Heartbeat now 6-hourly always-emit; Trail/Dojo scrapers parked; booking/weather run from /app writable layer.
