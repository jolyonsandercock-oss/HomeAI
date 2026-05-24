# U225 — Dashboard fixes + Booking.com reviews + comms restoration

**Realm:** owner (build/admin tooling). Per-realm scoping not required — all changes apply equally regardless of viewer realm.

**Trigger:** Jo's ad-hoc review on 2026-05-23 listing 10 dashboard issues + report that Telegram/email aren't working.

**Status:** in progress. Each item is a sub-deliverable; sub-tasks below are checked off as merged.

---

## T0 — Comms blocker (Vault sealed)

- [ ] Vault unsealed (needs Jo's passphrase via `bash /home_ai/.claude/scripts/u13-vault-unseal.sh`)
- [ ] Send test Telegram → confirm read
- [ ] Send test email → confirm read
- [ ] Document that u29-instructions-poll Gmail HTTP 500 was Vault-cascade (or surface as separate bug if it persists post-unseal)

Root cause: Vault sealed post-reboot. u29, u33, u66 cron jobs all fail at "fetch PG password from Vault". U221 auto-unseal sprint exists but not implemented — once we restore manual unseal, file that as P1 follow-up.

---

## T1 — Gross today is wrong (P1)

**Where:** `/pub` page tile "EPoS gross today" — `services/build-dashboard/static/pub.html:238`.
**Bug:** `/api/pub/snapshot` (`main.py:5470-5477`) sums **both** `site='malthouse'` and `site='sandwich'` rows from `touchoffice_fixed_totals`. The /pub page should only show pub (malthouse).
**Evidence:** 2026-05-23: API returns £2629.84 = malthouse £1520.69 + sandwich £1109.15.
**Fix:** Add `AND site = 'malthouse'` to the today_epos query in `pub_snapshot()`.
**Also covers Jo's "till sales not populating" if scoped to the /pub page (still surfaces sandwich on /cafe — see T6).**

- [ ] Patch query, recreate container, verify gross-today = £1520.69 (malthouse-only).

---

## T2 — Period KPI tiles restructure (P2 — bigger change)

**Where:** `index.html` KPI ribbon, lines ~617-673. Currently 6 single-value tiles with 7d sparklines: Labour% / Pub net / Café net / SPLH / Occupancy / Inbox.

**Jo's spec:** Replace the period KPI structure with three time-window boxes (Yesterday / 7d / 30d). Each box shows:
- Average in period + Total in period
- For both **Labour** and **Sales**
- With **percentage** (labour %)
- **Split by cafe and pub**
- **Bar chart** (not sparkline) per box
- Remove existing sparklines

**Data sources to wire:**
- `mart.daily_pub_sales` (or equivalent) for pub sales per day
- `mart.daily_cafe_sales` for cafe sales per day
- `v_workforce_forecast_vs_actual` or `tanda_*` for labour
- Need to confirm columns exist for daily totals by site

**Risk:** Larger UI change. May break responsive layout. Will design alongside Jo with a mock if needed.

- [ ] Confirm mart views exist for daily cafe/pub sales + labour
- [ ] Design the 3-box layout (preserves the rest of the ribbon)
- [ ] Implement bar chart component (replace `sparkSvg`)
- [ ] Wire data
- [ ] Verify rendered

---

## T3 — Nights sold: show `sold/total available` + ADR (P2)

**Where:** Likely the /pub or /caterbook page "Occupancy" / "Nights sold" tile. Need to confirm exact selector.
**Current:** `kpi.occupancy_pct + '%'` with subtext `occupied/total rooms`.
**Jo's spec:**
- Show format `sold/total available` explicitly
- Include **ADR (Average Daily Rate)** = room_revenue ÷ rooms_occupied (or ÷ nights_sold for a period)

- [ ] Locate exact tile
- [ ] Add ADR calculation (pull `room_revenue` already available; nights_sold may need a query)
- [ ] Re-render

---

## T4 — Average review score wrong + Booking.com reviews integration (P1)

**Where:** Review alert strip on `index.html:493-553` + drafts modal.
**Two bugs:**
  a. Average score figure is wrong (need to verify which view computes it)
  b. No Booking.com reviews are being pulled in. Currently the review pipeline pulls TripAdvisor/Google but not Booking.com.

**Scope:**
- [ ] Identify the average-score query (likely a view like `v_review_summary`)
- [ ] Audit: is it filtering by source/realm/date wrong?
- [ ] **Booking.com reviews:** read inbound Gmail; Booking.com sends review notifications to the property email. Parse those emails into the `guest_reviews` (or equivalent) table.
- [ ] Add a Booking.com panel to the dashboard (alongside Google/TripAdvisor)
- [ ] Include them in the recent-reviews list

**Risk:** Email parsing is unreliable — needs a defensive parser + monitoring.

---

## T5 — Bar tile changes (P2)

**Where:** Likely the `pub.html` or `index.html` — need to locate exact "Bar" tile. May be a kitchen/bar/cellar breakdown.
**Jo's spec:**
- Change "quantity" → "£ value"
- 7-day box: rolling 7-day total bar purchases
- 30-day box: rolling 30-day total bar purchases
- Show **wage total**, **sales total**, **wage %** per box
- **Colour-code** each box (green/amber/red on labour %)

- [ ] Locate "Bar" tile (it's likely on `pub.html` or a sub-page)
- [ ] Identify "Bar" semantic — is it "Bar dept" within touchoffice, or vendor purchases?
- [ ] Restructure tile with the three slots (£ value, 7d total, 30d total + wage/sales/%)

---

## T6 — Cafe prices, ice-cream/drinks, till sales not populating (P1)

**Where:** `/cafe` page (and possibly /touchoffice). Need to identify what's empty.
**Investigate:** is there a `touchoffice` import gap for site='sandwich'? Are there `cafe_prices` or `cafe_menu_items` tables?
**Cafe site code:** `sandwich` (confirmed in touchoffice_fixed_totals).

- [ ] Query touchoffice_fixed_totals — is sandwich data flowing? (Yes, today £1109.15 confirmed)
- [ ] Identify what "cafe prices" means (vendor invoice unit prices? menu prices?)
- [ ] Identify "ice cream/drinks" data — likely a touchoffice department or a separate manual entry
- [ ] Trace why each tile is blank

---

## T7 — Workforce: Tanda link stale (P2)

**Where:** `workforce.html` — staff list with a Tanda link per worker.
**Jo's report:** "staff says tanda link is stale" → the link is broken or points to the wrong Tanda profile.

- [ ] Locate the link generator in workforce.html or its data feed
- [ ] Audit: is it built from a stored URL, a computed `tanda_user_id`, or a guess?
- [ ] If stored: refresh from latest Tanda API export
- [ ] If guessed: fix the URL pattern

---

## Working order (proposed)

1. **T0 unseal** — Jo runs the script; until then comms is dead
2. **T1 gross today** — 1-line query fix, low risk, high signal
3. **T6 till sales / cafe prices populating** — diagnostic only first; identify what's missing
4. **T4a average review score** — query audit
5. **T3 ADR** — small fix
6. **T7 Tanda link stale** — small fix
7. **T2 period KPI restructure** — bigger UI change; Jo to sanity-check the layout sketch first
8. **T5 bar tile changes** — bigger UI change
9. **T4b Booking.com integration** — separate sub-track, biggest scope, needs email parser

---

## Decisions resolved (Jo, 2026-05-24)

- **T2 layout:** REPLACE the existing 6-tile KPI ribbon with the 3 period boxes (Yesterday / 7d / 30d).
- **T5 "bar":** it's the **bar sub-menu** — i.e. a sub-page/section, not the ribbon. Need to locate.
- **T4 Booking.com:** **fold in** with the existing review pipeline (single sprint, not separate).
- **T7 Tanda link stale:** **HOLD** — defer to later sprint. (Knock-on: T2/T6 labour-data section will note "labour ingest paused — see T7" rather than try to fix the ingest now.)

---

## Rollback

Each item ships as its own commit on `main` with a clear subject. If a UI restructure (T2/T5) breaks the rendered dashboard, revert that single commit. Data queries (T1, T4a, T6) revertable independently.
