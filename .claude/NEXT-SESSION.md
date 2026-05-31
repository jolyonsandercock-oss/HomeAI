# Next session — opening prompt (draft)

_Updated 2026-05-31. Read `MASTER.md` first._

## Invoice Intelligence — A + B + page + v2 + refinements all shipped
Specs/plans: `docs/superpowers/{specs,plans}/2026-05-3*-invoice-*`.

**Live & verified (all shadow / additive):**
- Capture: 613 invoices, 100% line canonicalisation, **99.1% categorised**.
- `/invoices` page: realm→vendor→dept→family→line waterfall, charts, **working exception verify/categorise** (vendor-wide), **provisional GP% panel** (honest WIP caveat).
- `/sales`: WIP 7-day rolling COGS + COGS% columns (italic).
- **Ongoing capture scheduled**: `projA-daily.sh` (cron 07:40) extracts new inbox invoices (capped $3) + `propagate_vendor_categories()` auto-tags from learned vendor categories.
- Brand consolidation: `product_brand_keyword` + `consolidate_brands()` (Guinness £2234 clean; add a keyword row to fix more).
- Diagnosed: the ~265 "unreadable" are harvester false-positives (no PDF / inline images) — **not lost invoices**; real-invoice capture is complete.

**Remaining (held):**
1. **Realm-auth gate (R4 / U147)** — the one big item: services off `postgres` superuser → per-realm RLS roles + enforce realm. High blast radius; needs a dedicated, staged, well-verified session. **Gate `/invoices` (and the realm toggle) behind real realm-auth before a work-only (Karl) login uses it — personal invoices are currently visible.**
2. GP% accuracy: extend `cogs_category_map` department mapping (many sales depts unmapped → 100% GP) + true periodic/stock-adjusted COGS (needs inventory counts) — GP% reads high until then.
3. Brand long-tail + new vendors: the verify queue + `product_brand_keyword` rows close these over time.

## Other open (pre-invoice)
- Xero Sync (P3) not live. Heartbeat 6-hourly always-emit. Trail/Dojo scrapers parked. booking/weather scripts run from /app writable layer (recreate wipes).
