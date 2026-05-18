# U85 — Desktop-first dashboard view

> Parallel to the mobile-first U84 IA. Same data, same realm toggle, same
> action queue — different chrome optimised for a 1280-1920px viewport.
> Collapsible burger menu, breadcrumbs, every table named with a stable
> code so Jo can say "fix §V02" and we both know exactly what he means.

---

## 1 · Design principles

| # | Principle |
|---|---|
| P1 | **One top-bar drives everything**: realm toggle + date-window picker. Every named section listens to both events and re-renders. No per-section filters. |
| P2 | **Sections are stable artefacts**, not anonymous div blocks. Every table/chart/tile gets a 3-character code (`T01`, `A01`, `V02` …) printed in the section header, and that code never moves. Renames are fine; codes are not. |
| P3 | **Burger left-rail** lists every section by bucket. Click → smooth-scroll to section + highlight. Closes on click outside (mobile) or stays pinned (desktop ≥ 1280px). |
| P4 | **Breadcrumbs** at top show `Work › Today › §T01 Today KPIs`. Click breadcrumb to navigate up. |
| P5 | **No new visual identity**: same dark-glass palette, same Alpine, same vendored deps. Just a different layout container. |

---

## 2 · Layout (1280px+)

```
┌────────────────────────────────────────────────────────────────────────────┐
│ ☰   Home AI   |Work|All|       Date: [Today][Yesterday][7d][30d][YTD][⟨⟩]  │
│                                                                  🔍 ⚙ Jo  │
├──────────────┬─────────────────────────────────────────────────────────────┤
│              │ Work › Today                                                │
│ Work         │                                                             │
│  • Today     │ §T01 · Today KPIs                                           │
│  • Actions   │ ┌─────────────────────────────────────────────────────────┐ │
│  • Docs      │ │ Cash   £-3,164    Open actions   317                    │ │
│  • Staff     │ │ Bookings  3       Docs 30d        0                    │ │
│  • Email     │ └─────────────────────────────────────────────────────────┘ │
│  • Finance   │                                                             │
│  • More      │ §A01 · Action Queue                                         │
│              │ ┌─────────────────────────────────────────────────────────┐ │
│ Private      │ │ Sev │ Source        │ Title                  │ Age │ ⋯  │ │
│  • Today     │ │  ●  │ exception     │ Dojo unsettled £663    │ 60d │    │ │
│  • Family    │ │  ●  │ till_variance │ -£220 pub 14 May       │  2d │    │ │
│  ...         │ └─────────────────────────────────────────────────────────┘ │
│              │                                                             │
│ Build        │ §B01 · Recent activity ...                                  │
│  ...         │                                                             │
│              │ (sections continue, ordered by section code prefix)         │
│ All          │                                                             │
└──────────────┴─────────────────────────────────────────────────────────────┘
```

At < 1280px the left rail becomes a slide-out drawer triggered by ☰.

---

## 3 · Section codes (the canonical registry)

The first character is the bucket; the next 2 digits are a stable index
within that bucket. **Once assigned, never reused or renumbered.** New
sections get the next free number; deleted sections leave a hole.

### T — Today (cross-cutting KPIs)
| Code | Name | Data source |
|---|---|---|
| T01 | Today KPIs · Work | slug `today_kpis_work` |
| T02 | Today KPIs · Private | slug `today_kpis_private` |
| T03 | Today's accommodation bookings | view `accommodation_bookings` filtered to today |
| T04 | Today's pub sales | `touchoffice_department_sales` for today |

### A — Actions / Alerts
| Code | Name | Data source |
|---|---|---|
| A01 | Action queue | slug `action_queue` |
| A02 | Till variances | view `v_till_variance_findings` |
| A03 | Vehicle alerts | view `v_vehicle_alerts` |
| A04 | Invoice overdue (last 7d) | `mart.exceptions` kind=invoice_overdue |
| A05 | Dead-letter queue | dead_letter table |

### V — Vendors / Spend
| Code | Name | Data source |
|---|---|---|
| V01 | Top vendors · window | slug `top_vendors_window` (date-driven) |
| V02 | Cost-centre split · window | derived from `vendor_invoice_inbox` |
| V03 | Recent invoices · window | slug-based list (date-driven) |
| V04 | Spend by category · window | slug `spend_by_category_window` |
| V05 | Vendor rules table | `vendor_site_rules` |
| V06 | Noise senders | `invoice_noise_senders` |

### C — Cash / Banking / Cards
| Code | Name | Data source |
|---|---|---|
| C01 | Account balances · now | slug `account_balances` |
| C02 | Credit cards | slug `credit_card_status` |
| C03 | Till reconciliation · window | `till_reconciliation` |
| C04 | Inter-entity transfers · window | `account_transfers` |
| C05 | Owings summary | slug `owings_summary` |

### L — Labour / Staff
| Code | Name | Data source |
|---|---|---|
| L01 | Labour by team · window | `v_daily_labour_by_team` |
| L02 | Ghost shifts | `mart.v_ghost_shifts` |
| L03 | Sales per labour hour · window | derived |
| L04 | Tanda last sync | `workforce_shifts` |

### E — Email / Inbox
| Code | Name | Data source |
|---|---|---|
| E01 | Open email tasks | `v_email_tasks_open` |
| E02 | Pending bot instructions | `bot_instructions` |
| E03 | Classifier uncertain | `v_classifier_uncertain` |
| E04 | Inbox volume · window | derived |

### D — Documents / Property / Family
| Code | Name | Data source |
|---|---|---|
| D01 | Mortgages | slug `mortgages_all` |
| D02 | Mortgage coverage | slug `mortgage_coverage` |
| D03 | Vehicles | slug `private_vehicles` |
| D04 | Children | `children` table |
| D05 | Recent documents · window | `documents` table |
| D06 | Net worth | slug `net_worth_summary` |

### B — Build / AI / Forensics
| Code | Name | Data source |
|---|---|---|
| B01 | AI pipeline status | slug `build_pipeline_status` |
| B02 | Model spend · 30d | slug `build_model_spend_30d` |
| B03 | Forensic summary | slug `build_forensic_summary` |
| B04 | Page-view telemetry · 7d | slug `route_telemetry_7d` |
| B05 | Cron health · 24h | derived |

### S — Sales / EPOS / Accommodation
| Code | Name | Data source |
|---|---|---|
| S01 | Daily GP · window | `v_daily_gp` |
| S02 | Sales by department · window | `touchoffice_department_sales` |
| S03 | Accommodation revenue · window | `v_daily_accom_revenue` |
| S04 | Dojo settlement · window | `v_dojo_daily` |
| S05 | Caterbook bookings · window | `caterbook_room_nights` |
| S06 | Pub wet/dry mix · window | `v_pub_sales_mix` |

### M — Maintenance / Recipes / Operations
| Code | Name | Data source |
|---|---|---|
| M01 | Recipes & PLUs | derived |
| M02 | Top purchases · window | slug `top_purchases_window` |
| M03 | Inventory health (placeholder) | TBD |

### R — Realm / All / Sitemap
| Code | Name | Data source |
|---|---|---|
| R01 | Sitemap · pages | `/api/all/sitemap` pages |
| R02 | Sitemap · slugs | `/api/all/sitemap` slugs |
| R03 | Sitemap · views | `/api/all/sitemap` views |

**Total: 47 sections.** Plenty of room for growth within each bucket.

---

## 4 · Routes

| URL | What it shows |
|---|---|
| `/desktop/work/today` | T01, T03, T04, A01 (filtered work-realm) |
| `/desktop/work/actions` | A01, A02, A03, A04, A05 |
| `/desktop/work/docs` | V01, V02, V03, V04 |
| `/desktop/work/staff` | L01, L02, L03, L04 |
| `/desktop/work/email` | E01, E02, E03, E04 |
| `/desktop/work/finance` | C01, C02, C04, C05, S01, S02, S03 |
| `/desktop/work/more` | M02 + sub-surface list |
| `/desktop/private/today` | T02, A03 (vehicles), D01 (mortgages preview) |
| `/desktop/private/family` | D04, T02, E04 (private inbox) |
| `/desktop/private/docs` | D01, D02, D03, D05, D06 |
| `/desktop/private/actions` | A01 filtered family/shared |
| `/desktop/private/more` | sub-surface list |
| `/desktop/build/pipelines` | B01, B05 |
| `/desktop/build/models` | B02 |
| `/desktop/build/forensics` | B03, A05 |
| `/desktop/all` | R01, R02, R03 |

Old mobile routes (`/work/today`, `/private/today`, …) keep working as the
phone view. `/desktop/<…>` is the additive desktop surface — Jo picks via
viewport width OR an explicit toggle in the header (cog menu).

---

## 5 · Date picker spec (the only filter)

Reuses `_components/date-window.js` already shipped. Single instance at
top of every desktop page. Default window per page:

| Page | Default | Notes |
|---|---|---|
| `/desktop/*/today` | Today | Most sections also show "Yesterday" comparison |
| `/desktop/work/docs` | 30d | Invoices benefit from a wider lens |
| `/desktop/work/finance` | 30d | |
| `/desktop/work/staff` | 7d | |
| Everything else | 7d | |

The picker emits `date-window-changed` on `window`; every section's
Alpine component listens and re-fetches. Sections that aren't
date-bound (D01 mortgages, V05 rules) ignore the event but still render.

---

## 6 · Burger menu spec

```html
<aside id="rail" class="fixed left-0 top-12 bottom-0 w-64 bg-slate-950/95
       border-r border-white/5 overflow-y-auto"
       :class="{'translate-x-0': open, '-translate-x-full': !open}">
  <nav role="navigation" aria-label="Sections">
    <details open class="section-group">
      <summary>Work</summary>
      <ul>
        <li><a href="/desktop/work/today" data-section="T01">§T01 Today KPIs</a></li>
        <li><a href="/desktop/work/today#T03" data-section="T03">§T03 Today bookings</a></li>
        ...
      </ul>
    </details>
    <details><summary>Private</summary>…</details>
    <details><summary>Build</summary>…</details>
    <details><summary>All</summary>…</details>
  </nav>
</aside>
```

- Pinned open on viewport ≥ 1280px
- Drawer (slide-from-left, closes on outside-click) on < 1280px
- Active section highlighted as user scrolls (IntersectionObserver)
- `:focus-visible` ring on every link
- Keyboard: Tab cycles; Esc closes drawer

---

## 7 · Breadcrumb spec

```html
<nav aria-label="Breadcrumb" class="text-sm text-zinc-400">
  <a href="/desktop/work">Work</a>
  <span aria-hidden="true">›</span>
  <a href="/desktop/work/today">Today</a>
  <span aria-hidden="true">›</span>
  <span class="text-zinc-100" aria-current="page">§T01 Today KPIs</span>
</nav>
```

Updates as user scrolls between sections (the active section's code +
name is the last crumb). Click any crumb to navigate up.

---

## 8 · Section partial template

Every section uses this shape:

```html
<section id="T01" class="glass rounded-lg p-4 mb-4 scroll-mt-16"
         aria-labelledby="T01-h">
  <header class="flex items-baseline justify-between mb-3">
    <h2 id="T01-h" class="text-base font-semibold">
      <span class="mono text-xs text-amber-300">§T01</span>
      Today KPIs
    </h2>
    <span class="text-xs text-slate-500" x-text="lastRefresh"></span>
  </header>

  <!-- skeleton / content / error states identical to mobile -->
</section>
```

The `§T01` mono prefix is what makes Jo's references work: he says
"§T01" or "Today KPIs"; both are unambiguous, and the prefix is
copy-paste-friendly.

---

## 9 · Implementation phases

### Phase D1 — Shell + components (4h)
- `/static/_components/desktop-header.html` — sticky top bar (burger + realm + date)
- `/static/_components/desktop-rail.html` — burger menu structure
- `/static/_components/desktop-section.html` — section frame
- `/static/_components/breadcrumbs.html`
- All three plug into existing realm-toggle.js + date-window.js
- IntersectionObserver wires up "active section" highlight

### Phase D2 — Today + Actions (3h)
- `/desktop/work/today` with T01, T03, T04, A01
- `/desktop/work/actions` with A01-A05
- Wire each section's data fetch + realm-handshake + date-window listener

### Phase D3 — Docs + Vendors + Spend (3h)
- `/desktop/work/docs` with V01-V04
- Reuse existing slugs (`top_vendors_window`, `spend_by_category_window`)

### Phase D4 — Finance + Cash (3h)
- `/desktop/work/finance` with C01, C02, C04, C05, S01, S02, S03
- Add inter-entity Sankey (deferred from U84 plan §6)

### Phase D5 — Staff + Email (2h)
- `/desktop/work/staff` (L01-L04)
- `/desktop/work/email` (E01-E04)

### Phase D6 — Private bucket (3h)
- `/desktop/private/today` (T02 + relevant private sections)
- `/desktop/private/family` (D04 + calendar)
- `/desktop/private/docs` (D01-D06)
- `/desktop/private/actions`

### Phase D7 — Build bucket (2h)
- `/desktop/build/pipelines`, `/desktop/build/models`, `/desktop/build/forensics`

### Phase D8 — Sitemap (1h)
- `/desktop/all` with R01-R03 as proper tables

### Phase D9 — Polish (2h)
- Active-section highlight + breadcrumb live-update
- Smooth-scroll + URL hash sync (`/desktop/work/today#T01`)
- Section codes in the URL `:target` highlight visually
- Print stylesheet — sections paginate cleanly when Jo wants to print

**Total: 23h.**

---

## 10 · Open questions

1. **Default landing**: when Jo hits `/desktop/`, where do we land? Suggest `/desktop/work/today`.
2. **Mobile/desktop switch**: viewport width auto-decides, or explicit toggle in cog menu? Suggest viewport + explicit override.
3. **Print**: do we need a CSV/Excel export per section, or is print + screenshot enough?
4. **Realm interaction**: when Jo's on `/desktop/private/docs` and clicks `[Work]`, do we navigate to `/desktop/work/today` or stay put and just re-filter? Suggest stay-put with re-filter, except for the dedicated private bucket which redirects to its work equivalent.
5. **Section codes in URLs**: `/desktop/work/today#T01` for deep link. Want a section anchor to be its own URL like `/desktop/sections/T01`? Probably no — over-engineering.

---

## 11 · What this changes for our workflow

You can now say:
- "Fix §V02 to also show TouchOffice categories" → I know exactly which view + page
- "Add a §E05 for classifier-uncertain detail" → I create E05 in the registry, add it to the relevant page
- "Drop §M03" → clean removal, no ambiguity

The section code is a **stable artefact** in our shared vocabulary,
independent of any UI rename or move. If a section moves between
pages (`§D01 Mortgages` could appear on `/desktop/work/finance` AND
`/desktop/private/docs`), it's still §D01 in both places.

---

## End of plan
