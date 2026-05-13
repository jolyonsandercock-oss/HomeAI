# U45 — View-page enrichment: invoices + workforce + accommodation

**Goal**: ship the per-page enhancements Jo asked for. Three tracks, one shared cross-cutting component (date picker + filter strip).

**Prerequisite**: U44 must ship first. Without invoice ingestion working end-to-end + buckets + GP view, the invoices view has no data to render.

**Remote-doable**: 100%.

## Cross-cutting (Track 0, ~45 min)

Reusable Alpine components (vanilla JS, no new deps):

- **`date-window-picker`**: 5 preset buttons + custom range. Presets: **Today** (1d) / **7d** / **MTD** / **30d** / **90d** + a date-range picker. Emits `(from, to)` Date objects.
- **`site-filter`**: top-of-page chip strip: **All / Pub / Café**. Emits `site ∈ {all, pub, cafe}`.

Both wired into the same persistence layer (localStorage key per page) so user's last selection is remembered.

Same component used on all 3 pages = consistent visual + behaviour.

## Track 1 — Invoices view (~2.5 hr)

Current: Tabulator showing all invoices. Add:

- **Top filter strip**: All/Pub/Café — filters invoices by `entity_id` AND maps to bucket (pub = wet+dry+head_office filtered to entity_id=1; café = cafe bucket; all = both).
- **Date window picker** (the new shared component). Filters by `COALESCE(delivery_date, invoice_date, received_at::date)`.
- **GP% header strip** (sticky, top of page below filters):
  - **Pub drink GP%** (= (pub_net − wet) / pub_net)
  - **Pub food GP%** (= (pub_net_food_proxy − dry) / food_proxy) — proxy = pub_net minus best-effort drink share
  - **Café GP%** (= (sandwich_net − cafe_stock) / sandwich_net)
  - **Overall GP%** (= (total_revenue − all costs ex overhead) / total_revenue)
  - Each tile shows: today's GP, 7-day avg, sparkline. Traffic light: drink<55%=rose, 55-65%=amber, >65%=green; food<60%/60-70%/>70%; café<35%/35-50%/>50%.
- **Per-invoice feedback textbox**: each row expandable with `<details>`; inline textarea + Save button → `POST /api/invoice/{id}/feedback`. Inline success/error toast.
- **PDF link** (per row): if `first_attachment_path` is non-null, render a "📄 view PDF" link → `/api/invoice/{id}/pdf`.

New endpoint: `/api/invoices/list?from=&to=&site=&include_statements=false&include_ignored=false` (paginated 100/page).

New endpoint: `/api/gp/daily?from=&to=&site=` returning the GP% rolling series for the header strip.

## Track 2 — Workforce view (~2.5 hr)

Current: per-team breakdown over last 30d. Add:

- **Top section: Today's rota** — table of (staff, dept, scheduled start–end, hours, cost @ hourly+on-cost). Status pill: scheduled / on-shift / completed.
- **Forecast vs actual variance card** (last 7 days): line chart, forecast cost from scheduled shifts vs actual cost from clocked hours. £ variance + % variance.
- **3 income-vs-cost cards**:
  - **Café**: café income (touchoffice sandwich_net) vs café team cost. Δ £ + ratio.
  - **FOH+Kitchen**: pub_net_sales (food + drink) vs (FOH + kitchen team cost). Plus sub-line: kitchen cost vs food-only proxy, FOH cost vs drink-only proxy.
  - **Housekeeping**: accom_revenue vs housekeeping team cost.
- **Date window picker** (shared component) — filter the variance + income-vs-cost cards. Default: this week.

Data sources:
- Today's rota: `workforce_shifts WHERE shift_date = CURRENT_DATE` joined to `workforce_users` + `staff_meta` (for hourly rate).
- Forecast: assume scheduled_start/scheduled_end exist on `workforce_shifts`; if not, we read `raw_payload->>'scheduled_start'` from the Tanda sync.
- Actual cost: existing computation in `v_daily_unit_economics.labour_cost_est`.

If Tanda's `/api/v2/shifts` returns scheduled-vs-actual, we already have the data — just need to surface both.

New endpoints:
- `/api/workforce/rota_today`
- `/api/workforce/forecast_vs_actual?days=7`
- `/api/workforce/income_vs_cost?from=&to=&team={cafe|foh|kitchen|housekeeping|all}`

## Track 3 — Accommodation view (~2 hr)

Currently mostly Tabulator showing bookings. Add:

- **Date window picker** (shared) — filter the whole page.
- **ADR card** (Average Daily Rate): single number = avg `rate_per_night` across `caterbook_room_nights` in the window. Plus 7-day-vs-30-day comparison.
- **Max/min per room card**: small grid, one row per room (Rm1-Rm8 + suite-9 + Flat). Min sold, max sold, sample count. Tab to switch between "current window" and "all time".
- **Occupancy now grid**: 3×3 visual layout of the 9 rooms (+Flat). Each room: green=occupied (with guest first name + checkout date) / slate=empty. Refreshes every 5 min.

Data sources: existing `caterbook_bookings` + `caterbook_room_nights` + `caterbook_daily_snapshots` (for today's arrivals/stayovers/departures JSON).

New endpoints:
- `/api/accommodation/adr?from=&to=`
- `/api/accommodation/rate_extremes?from=&to=`
- `/api/accommodation/occupancy_now`

## Acceptance

- [ ] All 3 pages have a consistent `date-window-picker` with 5 presets + range; selection persists per page in localStorage.
- [ ] Invoices page: filter chip (All/Pub/Café) works; date picker filters; GP strip renders; feedback textbox saves and reflects in `invoice_feedback`.
- [ ] Per-invoice PDF link opens the stored PDF when `first_attachment_path` is set.
- [ ] Workforce page: today's rota visible; variance card renders 7-day forecast-vs-actual; income-vs-cost cards show meaningful £ values.
- [ ] Accommodation page: ADR + max/min per room + occupancy-now grid; date picker filters ADR + extremes.
- [ ] No regressions to existing tables / endpoints / selftest baseline.

## Anti-scope

- **No new pipelines.** Pure UI on existing data.
- **No new cron jobs** (other than refresh).
- **No Authelia / Vault / image updates.**
- **No mobile-specific layout** beyond what Tailwind responsive utilities give for free.

## Files in scope

- `/home_ai/services/build-dashboard/static/components/date-window.html` — NEW (Alpine component)
- `/home_ai/services/build-dashboard/static/components/site-filter.html` — NEW
- `/home_ai/services/build-dashboard/static/invoices.html` — update for filter + picker + GP strip + feedback + PDF link
- `/home_ai/services/build-dashboard/static/workforce.html` — update for rota + variance + income-vs-cost cards + picker
- `/home_ai/services/build-dashboard/static/caterbook.html` — update for picker + ADR + extremes + occupancy grid
- `/home_ai/services/build-dashboard/main.py` — 7-9 new endpoints (per Track 1-3 listings)

## Total

~7-8 hr autonomous. Bigger than recent sprints because it touches 3 pages + 2 new components + ~8 endpoints.

## Sequencing within U45

1. Track 0 first (components) — everything else depends on it.
2. Track 1 (invoices) — highest user value; needs U44 fully landed first.
3. Track 3 (accommodation) — fully independent of U44; could go before Track 1 if waiting on U44 data.
4. Track 2 (workforce) — needs Tanda scheduled-shifts data confirmed.
