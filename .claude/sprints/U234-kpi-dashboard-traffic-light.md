# U234 — KPI dashboard: traffic-light + action levers

**Realm**: work (ARTL). **Remote vs in-person**: remote build; stocktake +
target-setting need Jo/staff input. **Risk**: low (additive dashboard + new
capture tables); the care item is honest labelling of provisional metrics.

**Vision**: a traffic-lighted KPI band on the dashboard with two audiences —
**management (Jo)** strategic, and **operational (staff)** day-to-day. Every KPI
shows green/amber/red against a benchmarked threshold, and **when amber/red it
shows a concrete lever** — the action staff should take that day to pull it back
to green. Benchmarks sourced from UK pub/inn 2025 industry data (see refs).

## Delivery order (per Jo, 2026-05-31)
1. ✅ **Spec** (this doc).
2. ◑ **Close Tier-1 data gaps** —
   - ✅ Targets seeded (`kpi_targets`, V218, benchmarked + draft levers).
   - ✅ Salaried-staff disambiguation (`salaried_staff`, V219): Karl Ramsey GM
     £40k from 2026-05-20; salary is source of truth, his hourly Tanda shifts
     excluded (labour corrected 18.6%→16.8%).
   - ⏸️ **Stocktake — DEFERRED** (Jo: "no stock levels currently, may be built
     in future"). GP/prime-cost stay flagged provisional until it lands.
   - ⚙️ **Covers ingestion — still open**: `epos_daily_reports.covers` exists
     but the TouchOffice bridge never populates it. Fix needed to unlock
     spend-per-head + covers/labour-hour. (Not yet done.)
3. ✅ **Traffic-light KPI section built + deployed** — `v_kpi_live` +
   `kpi_dashboard` slug (V220) + `KpiTrafficLight` component on the dashboard.
   7 buildable-now KPIs live with status + levers. **Provisional KPIs render
   muted (not green)** so incomplete-data metrics don't mislead.

### Live status of the 7 KPIs (2026-05-31)
prime_cost 31.3% · labour_pct 16.8% · food_gp 82.7% · wet_gp 95.1% (all
**provisional** — capture/labour incomplete) · sales_vs_lw +77% green ·
cogs_coverage 77% amber (lever shown) · cashup_variance £0 green.

### Remaining
- Covers ingestion (TouchOffice bridge) → spend-per-head, covers/labour-hour.
- Jo to refine the draft levers + tune thresholds in `kpi_targets`.
- Labour completeness: confirm hourly data covers all non-salaried staff
  (labour reads ~17%, low vs 25–30% norm — likely still partial).
- Tier-2/3 data (reviews, accom depth, utilities, recipes) per roadmap below.

---

## 1. KPI catalogue

Status key: ✅ computable now · ⚙️ pipeline gap (schema exists, not populated) ·
🔨 build gap (no data/table) · ⚠️ accuracy caveat.

### Management tier (Jo) — strategic, daily/weekly
| KPI | Source | Status | Benchmark | green / amber / red |
|---|---|---|---|---|
| **Prime cost %** (COGS + labour ÷ sales) — *master KPI* | purchases + workforce_shifts + sales | ⚠️ (both inputs partial) | healthy 60–65% | <62 / 62–68 / >68 |
| **Net sales vs same-day-last-week** (site+dept) | touchoffice_department_sales | ✅ | — | ≥0 / −10 / −20% |
| **Labour cost %** | workforce_shifts.cost_estimate ÷ sales | ✅ ⚠️ (reads 18.6% — likely hourly-only; salaried/mgmt missing) | 25–30% (avg now 31.2%) | <28 / 28–33 / >33 |
| **Food GP%** / **Wet GP%** | purchases + cogs_category_map + sales | ⚠️ provisional (lumpy, no stock) | food ~68%, wet 58–65% | food >68/62–68/<62 · wet >60/55–60/<55 |
| **COGS capture coverage** | v_cogs_capture_coverage (U232) | ✅ | — | >80 / 50–80 / empty |
| **Avg spend per head** | epos covers / dojo txns | ⚙️ covers not ingested | trend | trend vs 8-wk |
| **Sales per labour hour** | sales ÷ workforce hours | ✅ ⚠️ | trend | trend |
| **Cash-up variance** | till_reconciliation | ✅ | — | <£5 / £5–20 / >£20 |
| **Net profit margin** (period) | sales − all costs | 🔨 needs full cost capture | pubs 5–10% | >10 / 5–10 / <5 |
| **Occupancy / ADR / RevPAR** | caterbook | 🔨 thin (6 snapshots) | occ ~76%, ADR £146, RevPAR £110 | seasonal bands |

### Operational tier (staff) — today, actionable
| KPI | Source | Status |
|---|---|---|
| **Today's trade vs weather-adjusted forecast** | sales × weather model | ✅ (model to build) |
| **Staffing vs expected trade** (rostered hrs/£ vs forecast sales) | workforce_shifts (forward roster) + forecast | ✅ |
| **Covers today vs typical** | epos covers | ⚙️ not ingested |
| **Till variance since last cash-up** | till_reconciliation | ✅ |
| **Hygiene actions outstanding** | trail_reports | ✅ |
| **Rooms to turn / arrivals tonight** | caterbook | 🔨 thin |
| **Reviews awaiting response** | guest_reviews | 🔨 empty |

---

## 2. Traffic-light engine

Extend the (currently empty) `ops_thresholds` table — one row per KPI:

```
kpi_key            text PK     -- e.g. 'labour_pct', 'food_gp', 'prime_cost'
label              text
tier               text        -- 'management' | 'operational'
unit               text        -- '%','£','ratio'
direction          text        -- 'lower_better' | 'higher_better'
green_bound        numeric     -- threshold between green/amber
amber_bound        numeric     -- threshold between amber/red
lever_amber        text        -- action shown when amber
lever_red          text        -- action shown when red
source_slug        text        -- which slug feeds the current value
active             bool
```

A single slug `kpi_dashboard` joins each KPI's live value (via its `source_slug`
/ a computed CTE) to its threshold row and returns
`{kpi_key, label, tier, value, status(green|amber|red), lever}`. Frontend renders
a traffic-light card per KPI; amber/red cards surface the `lever` text.

## 3. Levers framework (action recommendations)

Jo authors the lever text (operational knowledge); seed examples:
- **prime_cost red** → "COGS+labour >68% of sales. Cut a shift today, check GP on top sellers, hold non-urgent orders."
- **labour_pct red** → "Send one team member home; trim tomorrow's open shift; push covers (specials, upsell coffee/dessert)."
- **food_gp red** → "Check portions + wastage log; flag supplier price rises to Jo; pull slow movers from the board."
- **sales_vs_forecast amber on fair weather** → "Board out front, open the garden, run specials, prompt upsells."
- **till_variance red** → "Recount, check void/refund log, escalate to Jo."
- **hygiene red** → "Complete Trail action items before service."

## 4. Data-gap roadmap

**Tier 1 — unblock core KPIs (this sprint):**
- **Targets / thresholds** — seed `ops_thresholds` with the benchmarked defaults
  above (autonomous); Jo tunes + writes levers. *No new data needed.*
- **Stock counts** 🔨 — new `stocktake` capture: table
  (`stocktake(id, count_date, area, item/category, valuation, counted_by, realm)`)
  + a simple entry surface (mobile-friendly), weekly wet + monthly food. Unlocks
  **true periodic COGS/GP** (opening + purchases − closing) — the #1 accuracy fix.
- **Covers ingestion** ⚙️ — `epos_daily_reports.covers/transactions/avg_transaction`
  exist but are never populated. Fix the TouchOffice scrape/bridge to capture the
  covers figure (confirm TouchOffice exposes it). Unlocks spend-per-head +
  covers/labour-hour.
- **Labour completeness** ⚠️ — verify whether `cost_estimate` covers all staff
  (salaried/management) or hourly-only; document the caveat or extend.

**Tier 2 — reputation & demand:**
- Reviews capture (Google/Booking.com/TripAdvisor) → `guest_reviews`.
- Accommodation depth (occupancy/ADR/RevPAR/pace) → richer caterbook ingest.
- Wastage/spoilage log.

**Tier 3 — cost control:**
- Utility consumption (kWh/m³, not just £).
- Recipe/menu costings (`recipes` empty) → theoretical GP + menu engineering.
- Cashflow forecast.

## 5. Caveats (must show on the UI)
- **GP% provisional** — invoice-lumpy until stocktake lands (U232/U234 stock).
- **Labour % likely understated** — reads 18.6% vs 25–30% norm; probably
  hourly-rostered only. Validate before treating as authoritative.
- **Prime cost inherits both caveats** — flag as provisional until stock + labour
  completeness are resolved.

## Benchmark sources
UK pub/restaurant 2025: food GP ~68% / wet 58–65% / labour 25–30% (now ~31%) /
prime cost 60–65% / net 5–10%. Accommodation: UK occ ~76%, England ADR £146,
RevPAR £110. (SmartPubTools, GetJelly, LocalBrandHub, Knight Frank UK Hotel
Dashboard Q3 2025, VisitBritain.)
