# UX deep-dive + autonomous backlog (U185-U195)

A source-code audit of `homeai-frontend` (1,293 lines across 11 pages),
combined with a sweep of SPEC §11b + STRETCH §3, produced the work below.
Everything here is **autonomously executable** — no Jo-input required
(though Jo's UX walkthrough still unlocks the **separate** U179 series
that needs human eyes).

---

## Part 1 — UX deep-dive findings

### What's strong already
- **Dark industrial palette** (#0f0f0f bg, amber accents, tabular numerals) — professional, scannable.
- **Traffic-light colour helpers** (`grossClass`, `labourClass`, `trailClass`) defined and used.
- **`KPICard` component supports sparklines + delta + rolling average** out of the box. Just rarely fed data.
- **`recharts` library already installed** (`^2.15.4`) and unused.
- **Click-through tiles** — every KPI tile is a `<Link>` with hover affordance.
- **Section + tile pattern** consistent across all 11 pages.

### What's missing — patterns of confusion

1. **`KPICard` has `spark?` prop but ~90% of usage doesn't pass it.** Free density that's left on the table.
2. **Empty states are generic** — same "PlaceholderState" for "no data ingested" vs "0 sales today" vs "nothing has happened yet".
3. **Numbers without context** — "£2,931" is shown raw. No "vs typical Mon £3,400" / "in the lowest 20% of similar days".
4. **No visual comparison side-by-side** — pub vs cafe shown as two numbers, not a small bar.
5. **No heatmaps anywhere** — week × room occupancy, week × till variance, etc. would scan in 1s.
6. **Action queue is a flat list** — should be urgency-stratified bands (overdue, today, this week, backlog).
7. **No revenue waterfall** — Revenue → COGS → Labour → Contribution is the most important narrative. Show it as a flow.
8. **No mini-distributions** — "today's £X" should be a dot on a violin/range showing "where this sits in last 30 days".
9. **Tide visualisation is plain text** — a 100×20px sine-wave sparkline would convey "low at 14:00, high at 21:00" instantly.
10. **No staff rota timeline** — 8 hours × 8 people = 64 cells; right now it's a table when it should be a Gantt-strip.
11. **Anomaly badges absent in week-strip** — outlier days (low cover count, big variance) should pulse or border.
12. **Today vs same-DoW prior week not shown contextually** — only on the bespoke "today vs last week" tile.
13. **No print/share affordance** — kitchen-prints and end-of-day proofs are paper-bound activities.
14. **No "last refresh" timestamp** — when a slug doesn't auto-refetch, the user can't tell if it's live.
15. **No drill-down breadcrumb** — clicked from `/app/sales` to a breakdown — how does staff get back?

### Specific visualisation recommendations (impact-ranked)

**Tier 1 — high impact, ½ day each:**

| viz | where it goes | what it shows | builds with |
|---|---|---|---|
| Sparkline-by-default on every KPI | every tile | 7d trend silently in the corner | already in KPICard, just feed it |
| Today-vs-typical band | revenue tile + labour tile | dot on a horizontal range (P10/P50/P90) showing where today sits in last 30d | recharts `ReferenceArea` + `Scatter` |
| Pub-vs-Cafe split bar | revenue tile | mini side-by-side bar so the £ ratio reads instantly | recharts `BarChart` mini |
| Revenue waterfall | `/app` and `/sales` | revenue → COGS → labour → contribution as connected blocks | custom SVG or recharts `Bar` with negative |
| Tide-curve sparkline | week-strip + `/rooms` | sine-curve indicating high/low across the day | custom SVG (12 points) |

**Tier 2 — medium impact, ~½ day each:**

| viz | what it shows |
|---|---|
| Occupancy heatmap | week × room (28 cells) showing booked/available with colour intensity |
| Rota Gantt strip | staff × time-of-day on `/work/staff` |
| Cash-drift sparkline | per-till 30-day cumulative variance line |
| Stratified action queue | overdue / today / this week / backlog buckets |
| Anomaly-pulse on week strip | days where revenue or labour% sit outside P10/P90 get an amber border |

**Tier 3 — polish, ~¼ day each:**

| viz | what it shows |
|---|---|
| Print-friendly view per page | `?print=1` query param strips chrome |
| Refresh-pill on tiles | "live 30s ago" / "stale 4h" indicator |
| Drill-back breadcrumb | "Back to dashboard" pill on every drill page |
| Contextual empty states | per-slug `empty_template` reading from `query_whitelist.notes` |
| Weather-icon parity | tide + sunset get matching glyphs |

---

## Part 2 — autonomous sprint plan (U185-U195)

11 sprints, all backend or visualisation work. None require Jo's eye.
**Sequence by impact-per-hour**:

### **U185 — Sparkline-by-default + last-refresh pill** (½ day)
Backfill every KPICard usage to pass `spark` from a `<slug>_spark` companion slug.
Add `<RefreshPill at={...} />` component reading from the slug's lastFetchedAt.
**Autonomous** — pure component + slug work.

### **U186 — Today-vs-typical band component** (½ day)
New `<RangeBand value low p10 p50 p90 high />` component. Wire into the revenue + labour tiles + daily P&L. Computes via `<slug>_today_vs_p10_p90` slug returning the percentile of today.
**Autonomous** — extends existing SVG sparkline patterns.

### **U187 — Revenue waterfall** (¾ day)
`<Waterfall steps={[...]} />` component. Wire onto `/app` and `/sales`. Inputs from `daily_pnl` slug.
**Autonomous** — uses recharts which is already installed.

### **U188 — Tide-curve sparkline** (¼ day)
12-point SVG sine curve showing the day's tides. Replaces text on the week-strip.
**Autonomous** — small component.

### **U189 — Occupancy heatmap** (½ day)
7 days × 12 rooms grid of 84 cells, colour-mapped: booked (filled) / available / blocked / stale. Wire onto `/rooms`.
**Autonomous** — pure SVG.

### **U190 — Stratified action queue** (½ day)
Update `frontend_action_queue` to return `urgency_bucket` ('overdue', 'today', 'this_week', 'backlog'). Refactor `/tasks` page to show four bands.
**Autonomous** — slug + page refactor.

### **U191 — Contextual empty states** (½ day)
Add `notes` (or `empty_state_md`) reading from `query_whitelist`. Refactor `<PlaceholderState>` to consume per-slug context. Add data for the 11 "correctly empty" slugs identified in earlier audit.
**Autonomous** — schema + component.

### **U192 — Anomaly pulse on week strip** (¼ day)
For each day in the strip, compute z-score of revenue vs DoW-history. |z| > 1.5 = amber border + small bell glyph.
**Autonomous** — wraps existing data.

### **U193 — Print-friendly view** (¼ day)
`?print=1` query param hides nav + maximises tiles, drops dark background. Useful for kitchen prep sheets + end-of-day reports.
**Autonomous** — CSS-only.

### **U194 — Drill-back breadcrumb** (¼ day)
`<Breadcrumb>` component above page header. Persists `?from=...` query param so back-links work.
**Autonomous** — React routing.

### **U195 — Pub-vs-cafe split bar + side-by-side comparisons** (¼ day)
Replace the inline pub/café spans with a 2-bar horizontal mini-chart.
**Autonomous** — recharts.

---

## Part 3 — SPEC + STRETCH review (autonomous tasks discovered)

Sweep of SPEC §11b + STRETCH §3 surfaced 7 autonomous candidates:

### **U196 — Beer Garden Oracle** (SPEC §11b, ½ day)
Met Office DataPoint API forecast for Tintagel. Correlate against historical TouchOffice covers. Slug `beer_garden_recommendation_today` returning a forecast-aware recommendation. Surface on `/work/today`.
**Autonomous** — free API, existing data.

### **U197 — Ice Cream Oracle** (SPEC §11b, ½ day)
Cafe-specific demand prediction from weather + footfall history. `cafe_demand_forecast_today` slug.
**Autonomous**.

### **U198 — Vault health monitor + service watchdog** (STRETCH §3.1, ¾ day)
- Slug `vault_seal_history_24h` querying vault status snapshots.
- Cron `*/30 * * * *` checks seal; if sealed unexpectedly → Telegram alert.
- Slug `containers_restart_storm` — any container restarted > 2x in last hour.
- Wire into U165 freshness watcher.
**Autonomous**.

### **U199 — Children's milestone vault** (SPEC §11b — but `personal` realm)
**DEFER** per Jo's standing instruction to keep personal realm postponed until work env mature.

### **U200 — Competitor watch** (SPEC §11b, ½ day)
Weekly Sunday 03:30 scrape (via email-notification path mirroring U163, since direct scraping is DataDome-blocked). Alert on rating drift > 0.3.
**Autonomous** — but needs Jo to subscribe to TripAdvisor competitor-property notifications first. Soft-defer.

### **U201 — Docker image-tag pinning** (STRETCH §3.1, ¼ day)
Pin all `:latest` tags in `docker-compose.yml` to specific versions per STRETCH guidance. Slug `images_unpinned_or_stale_check`. Cron monthly.
**Autonomous**.

### **U202 — Full weekly backup-all** (STRETCH §3.7, ½ day)
`scripts/backup-all.sh` doing DB + Vault unseal-keys + n8n workflows + git push to off-host backup. Weekly Sunday 03:00 cron. Telegram on completion or failure.
**Autonomous** — extends existing backup-nightly.

### **U203 — Static-image performance / Lighthouse run** (½ day)
Run Lighthouse against each page; capture LCP/CLS/FID. Surface as slug `frontend_perf_audit_weekly`. Surface regressions.
**Autonomous**.

---

## Suggested execution order (next session)

```
Tier-1 viz (high impact):                      Stretch / SPEC follow-through:
  U185 spark-default ──┐                          U201 pin Docker tags    ┐
  U186 today-vs-typical ─┤                        U202 backup-all weekly  ├─ all parallel
  U187 revenue waterfall │   chain into           U198 vault watchdog     │
                         ├─ tier 2:               U196 beer-garden oracle ┘
  U195 pub vs cafe bar ──┘  U188 tide curve
                            U189 occupancy heatmap
                            U190 stratified action queue
                            U191 contextual empty states
                            U192 anomaly pulse
                            U193 print view
                            U194 drill-back breadcrumb
```

A reasonable single-session target: **U185 + U186 + U187 + U198 + U201 + U202** = ~3 days of autonomous work covering the highest-impact tier-1 viz + safe security/backup hardening.

---

## What this batch deliberately does NOT touch

- **Jo-eye UX iterations (U179-U184)** — those still need the walkthrough.
- **Personal-realm work** — postponed per standing instruction.
- **Trail integration (U156)** — still needs interactive OIDC pair.
- **Service-migration U151 T4** — still needs sign-off.
- **U199 children's milestone vault** — personal realm, deferred.

---

## Ready to execute

Pick a slice. I'd recommend:
1. **U185** (spark-default everywhere) — most visible impact for least effort.
2. **U187** (revenue waterfall) — strongest narrative for daily decisions.
3. **U202** (backup-all weekly) — closes a real safety gap.

Or "all of U185-U195 in order" if you want the full UX visualisation push.
Or "do everything in this plan" if you want the lot.
