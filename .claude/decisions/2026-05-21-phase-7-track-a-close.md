# ADR — Phase 7 Track A closed

**Date:** 2026-05-21
**Status:** **Decided**
**Predecessor:** `2026-05-21-phase-6-close-final.md`
**Scope:** Revenue close-the-loop (technical track).

---

## Verdict

Track A complete. 6 sprints (U173-U178) shipped in one autonomous session. Revenue side now mirrors what Phase 6 did for the cost side: every signal aggregated, classified, and queryable.

## What Track A delivered

### U173 — VAT-relevant classification
- V191 `vat_classification_rules` table + bootstrap (11 default UK rules).
- `vat_rate` column on `touchoffice_department_sales`, backfilled 2,370 rows.
- Slugs: `vat_owed_quarter`, `vat_unclassified_lines_30d`.
- **Live finding**: current quarter VAT owed = £35,995 on £215,970 revenue (rooms + food/drink).

### U174 — Profitability slugs
- V192 — 4 new slugs: `revenue_by_room_type_30d`, `plu_top_sellers_30d`, `top_revenue_drivers_today`, `gross_margin_30d`.
- **Live finding**: 30-day gross margin 83.9% (revenue £119,764 − cost-of-goods £19,258).
- Per-room-type: 6-dbl earns most (£3,658 / 26 nights). ACCOMODATION PLU = single biggest revenue driver (£21,833 / 30d).

### U175 — Revenue forecasting
- V193 — `revenue_forecast_28d` (per-day with P10/P50/P90 confidence) + `revenue_forecast_next_4_weeks` (weekly roll-up).
- Combines: confirmed forward bookings + DoW-historical patterns + bank-holiday flag.
- **Live**: today (Thu) P50 £2,602; Sat P50 £3,239; Sun P50 £3,304; bank-hol Mon P50 £2,656.

### U176 — Cash variance operational
- V194 — `cash_variance_unexplained_7d` + `cash_drift_per_till_30d`.
- **Live finding**: 13 days in last 30 with variance >£10, total absolute variance £929.65; 2 days last week need investigation (2026-05-14 −£220 "Freja"; 2026-05-20 −£75 "Tikes").

### U177 — VAT return prep
- V194 — `vat_return_quarter` slug (date_param).
- **Live finding**: Q2 2026 net VAT due £30,884 (output £35,995 − input £5,111).

### U178 — Daily P&L
- V195 — `daily_pnl` slug per-day with revenue / supplier cost / labour cost / contribution.
- **Live**: 2026-05-19 contribution £5,177 (rev £5,177, supplier £0, labour £0 — needs workforce_shifts.cost_estimate populating).

## Track A migration list

V191, V192, V193, V194, V195 — all idempotent, all reversible.

## What Track A explicitly deferred

- **Daily P&L narrative email**: V195 has the slug; the email script extension to U159's pattern is trivial but deferred. Add when Jo wants to receive it daily.
- **Per-PLU recipe-cost attribution**: needs recipe schema (V83/V90) fully populated. Phase 8.
- **Per-room-type forecast** (current is aggregate): refinement, low-priority.
- **Tide/weather as forecast inputs**: explicit hook present but not yet weighted.

## Findings worth flagging

1. **workforce_shifts.cost_estimate is NULL** for most rows. Daily P&L labour figure is misleading. Either Tanda sync isn't populating it, or a separate calculation step is missing. **U176 follow-up: backfill cost_estimate from base_pay_rate × hours_worked.**

2. **Cash drift £929.65 / 30d** on the pub till is operationally significant (~£30/day average absolute). 2026-05-14's −£220 stands out — worth Jo asking Freja.

3. **VAT input £5,111 vs output £35,995** = net VAT £30,884 owed. 7:1 ratio output:input is normal for hospitality but worth confirming the input side captures all xero_bill_lines with valid tax_total.

4. **Forecast confidence is wide**: Saturday P10 £1,757 vs P90 £4,277 — 2.4x range. Normal for hospitality but means Jo shouldn't over-anchor on the P50 number.

## Phase 7 status

- **Track A: ✅ done.** Revenue close-loop complete.
- **Track B: ⏸ pending.** UX sprint series + Karl dress rehearsal — needs Jo's calendar + eye on rendered pages.

Phase 7 closes when Track B lands. Phase 8 (customer-facing) becomes the natural next.
