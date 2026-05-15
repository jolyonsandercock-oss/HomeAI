# U84 — Home AI dashboard UX restructure

> **Handoff status:** plan refinement in progress on Ultraplan.
> Canonical remote: <https://github.com/jolyonsandercock-oss/homeai-plans-.git>
> Local seed: `/home/joly/.claude/plans/sorted-toasting-walrus.md`.
> Wire up locally with:
> ```
> cd /home/joly && \
>   git remote add origin git@github.com:jolyonsandercock-oss/homeai-plans-.git && \
>   git push -u origin main
> ```
> (SSH URL preferred; the `.git` HTTPS form above also works if you've a token configured.)

## Context

The dashboard has grown to **23 HTML pages and 58 API endpoints** in a flat URL structure. Every page lives at its own root (`/finance`, `/workforce`, `/vehicles`, `/dojo`, `/touchoffice`, `/m`, etc.). There's no information architecture: each surface was added as a sprint deliverable and there's no curated path between "I just want today's number" and "I want to debug a Tanda sync gap".

Jo needs four distinct mental models, not 23 pages:

1. **Build** — what the AI itself is doing (services, models, tokens, costs, sovereignty)
2. **Work** — running the pub/cafe/estates business day-to-day
3. **Private** — personal/family operations (mortgages, vehicles, children, cash)
4. **All** — a searchable sitemap for the long tail of detail screens

The current `/index` (Mission Control) mixes hardware tiles, agent queues, finance KPIs, and weather. The current `/m` is the only screen designed for phone use. There's no global realm switcher so private and work data co-mingle visually.

This plan restructures the dashboard around those four mental models, mobile-first, with a realm toggle in the header that drives data filtering on every page without changing URLs.

---

## Decisions locked

| Question | Answer |
|---|---|
| Top-level structure | **Realm toggle in the header** (not URL prefixes). Top bar shows `[ Work | Private ]` segmented control; Build and All are separate tabs that ignore the toggle. |
| Device priority | **Mobile-first for both Work and Private.** Extend the `/m` design language. Desktop is a wider variant of the same tiles. |
| Build scope | **AI ops + Sovereignty + Forensics** — services, model spend, dead-letter inspection, dreaming state, drift detection. Everything currently on `/index` plus what's on `/agents-ops` and `/forensics`. |
| All-bucket UX | **Sitemap-style page with a search bar.** Like a Notion all-pages view: every page + slug + view listed, filterable, with last-touched timestamps. |

---

## Target architecture

### Top-level navigation (sticky header on every page)

```
┌──────────────────────────────────────────────────────────────────────────┐
│ ⌂ Home AI │ [ Work │ Private ] │  Build  │  All  │  🔍 search  │  ⚙  │ Jo │
└──────────────────────────────────────────────────────────────────────────┘
```

- **Logo + breadcrumb** (left) — clickable returns to `/today` of the active realm.
- **Work/Private segmented control** — the active management context. Persists in `localStorage` + `X-Realm` cookie. Determines what every page sees.
- **Build** — opens the AI ops surface. Realm-agnostic (Jo is always the owner here).
- **All** — sitemap + global search. Realm-agnostic.
- **Settings cog + identity** — Authelia logout, theme, realm enforcement state, link to `/build/health`.

### Information architecture (sitemap)

```
HOME AI
├── (header) Realm: WORK | PRIVATE  ─────────────┐
│                                                │  this toggle drives
├── Work                                         │  X-Realm on every
│   ├── Today      → KPI dashboard               │  Work + Private call
│   ├── Staff      → rota, labour cost, sales-   │
│   │               per-hour, ghost shifts        │
│   ├── Email      → inbox queue, email-tasks,    │
│   │               classifier review             │
│   ├── Docs       → invoices, receipts,          │
│   │               contracts, expiry alerts      │
│   ├── Actions    → reconciliation, fraud, gaps  │
│   │               + the things-Jo-must-do queue │
│   └── More       → dojo, caterbook, touchoffice,│
│                   GP, recipes, accommodation    │
│                                                │
├── Private                                      │
│   ├── Today      → net worth, cash, upcoming    │
│   │               bills, vehicle alerts         │
│   ├── Family     → children, schools,          │
│   │               medical, calendar             │
│   ├── Email      → personal email queue         │
│   ├── Docs       → mortgage statements,         │
│   │               vehicle docs, family papers   │
│   └── Actions    → MOT/insurance due, mortgage  │
│                   coverage gaps, calendar       │
│                   conflicts                     │
│                                                │
├── Build  (realm-agnostic)                      │
│   ├── Pipelines  → /agents-ops + cron health    │
│   ├── Models     → AI usage, costs, tokens,    │
│   │               drift, benchmarks             │
│   ├── Forensics  → dead-letters, events,        │
│   │               anomalies, dreaming           │
│   ├── Spec       → SPEC.md, decisions, research │
│   └── Sovereignty → context pressure, lifecycle,│
│                    tier residency, sparklines   │
│                                                │
└── All  (realm-agnostic)
    └── Sitemap with search bar — every page,
        every slug, last-touched timestamp,
        owner realm tag.
```

### Realm toggle: how it works

| Layer | Implementation |
|---|---|
| User action | Click `Work` or `Private` segmented control in header. |
| Client-side | Write `localStorage.setItem('homeai.realm', 'work'|'family')`. Reload the page (or hot-swap via Alpine event). |
| AJAX header | A shared `fetch` interceptor adds `X-Realm: <choice>` to every `/api/*` request. |
| Server | Existing `realm_middleware` in `main.py:497-529` reads `X-Realm` header (already implemented). The realm scope cascades into RLS via `set_config('app.current_realm', …)`. |
| Persistence | `X-Realm` cookie (set by JS) means deep links to a page also carry intent. Authelia's Remote-Groups header still overrides for owner-only screens (Build / All). |
| Visual cue | Active realm chip is colour-coded: `work` = amber (#f59e0b), `private` = green (#34d399). Cog menu shows current realm + a "test as other realm" option for owner. |

Critically, this means `/finance`, `/workforce`, `/m`, `/vehicles` etc. **don't need new URLs** — they just get a header that adjusts what they show.

---

## Page-by-page wireframes

> All wireframes are **mobile-first** (375px viewport). Desktop is the same layout in a wider grid (3-4 columns instead of 1-2). Dark glassmorphic continues; no theme change.

### Work · Today (Mobile)

```
┌─────────────────────────────────────────┐
│ ⌂ Home AI │ [ Work* │ Private ] │ … 🔍 │
└─────────────────────────────────────────┘
  Friday · 15 May 2026 · 14:21          ●live

╔═════════════════════════════════════════╗
║ TODAY                                   ║
╠═════════════════════════════════════════╣
║  ● Labour %       28.4%   ▼ -1.7 LW    ║
║  ╰─ £342 saved vs LW                   ║
║                                         ║
║  ● Takings        £4,201  ▲ +£312 LW   ║
║  ╰─ pub £3,180  cafe £1,021            ║
║                                         ║
║  ● GP (rolling 7d) 64.8%  ● target 65% ║
║                                         ║
║  ● Bookings       6 in    /14 cap      ║
║  ╰─ £820 tonight    next: tomorrow 9   ║
║                                         ║
║  ● Cash on hand   £4,938  ● healthy     ║
║  ╰─ ART -£3,164 (overdraft)            ║
╚═════════════════════════════════════════╝

──────── ACTION QUEUE ─────────────────────
  🔴 5 unsettled Dojo batches   →  Resolve
  🟡 18 invoices needs-review   →  Triage
  🟡 1 mortgage stmt missing    →  Scan
──────────────────────────────────────────

──────── WHAT HAPPENED YESTERDAY ──────────
  [sparklines: takings/labour/covers,
   14-day]
──────────────────────────────────────────

──────── PULSE ────────────────────────────
  TouchOffice  4m ago    ● live
  Tanda        7h ago    ● synced
  Dojo         1d ago    ● lagging
  Email queue  0 pending ● clear
──────────────────────────────────────────
```

### Work · Staff (Mobile)

```
╔═════════════════════════════════════════╗
║ STAFF · TODAY                           ║
╠═════════════════════════════════════════╣
║ ON SHIFT NOW                            ║
║  Tikes      08:30→16:00  £74            ║
║  Freja      11:00→23:00  £138           ║
║  Charlie    18:00→23:00  £62            ║
║  ─── 3 on, £274 to date               ║
║                                         ║
║ COMING NEXT 4 HRS                       ║
║  Sam        15:00→23:00                ║
║                                         ║
║ LABOUR % LIVE                           ║
║  ████████░░░░░░░░  28.4%               ║
║  ╰─ target <30%  ● ok                  ║
╚═════════════════════════════════════════╝

──────── GHOST SHIFTS ─────────────────────
  9 days flagged: sales but no shifts.
  Most recent: 2026-05-05 (£3,036 at pub)
  → Review
──────────────────────────────────────────

──────── WEEKLY ROTA ─────────────────────
  [Mon-Sun condensed grid, names + hours]
──────────────────────────────────────────

──────── INSIGHT ──────────────────────────
  Sales per staff-hour ▲ vs LW
  [tiny bar chart]
──────────────────────────────────────────
```

### Work · Email (Mobile)

```
╔═════════════════════════════════════════╗
║ EMAIL                                   ║
╠═════════════════════════════════════════╣
║ INBOX (work mailbox)                    ║
║  • 3 new since yesterday               ║
║  • 0 marked urgent                     ║
║                                         ║
║ NEEDS YOUR EYE                          ║
║  Forest Produce — invoice query 2d ago ║
║  Hodgsons     — VAT due 31 May          ║
║  Brewers      — credit note Q&A         ║
║                                         ║
║ EMAIL-TASKS OPEN                        ║
║  4 tasks extracted from this week's    ║
║  emails. → /work/email?tab=tasks       ║
║                                         ║
║ CLASSIFIER QUEUE                        ║
║  2 emails flagged as uncertain.        ║
║  → Confirm                              ║
╚═════════════════════════════════════════╝
```

### Work · Docs (Mobile)

```
╔═════════════════════════════════════════╗
║ DOCS                                    ║
╠═════════════════════════════════════════╣
║ INVOICES                                ║
║  Extracted   172                        ║
║  Needs review 18  → /invoices/needs-... ║
║  Awaiting payment ?                     ║
║                                         ║
║ CONTRACTS                               ║
║  Active: 7                              ║
║  Expiring 60d: 1 (Crossbow lease)      ║
║                                         ║
║ COMPLIANCE                              ║
║  FSA cert       valid to 2027-03        ║
║  Pub licence    valid to 2026-09        ║
║                                         ║
║ DROP TO ADD                             ║
║  Drop a PDF into                        ║
║  /mnt/shared_storage/scans/inbox or    ║
║  scan via Brother → auto-OCR'd.        ║
╚═════════════════════════════════════════╝
```

### Work · Actions (Mobile)

```
╔═════════════════════════════════════════╗
║ ACTIONS                                 ║
║ "things only you can decide"            ║
╠═════════════════════════════════════════╣
║ 🔴 SEVERITY: CRITICAL                   ║
║  None firing.                           ║
║                                         ║
║ 🟠 SEVERITY: HIGH                       ║
║  • 5 unsettled Dojo batches             ║
║    £4,892 unmatched in NatWest         ║
║    → Onboard 48885517 CSV               ║
║                                         ║
║  • 9 ghost-shift days flagged           ║
║    May 1-5, both sites                  ║
║    → Review                             ║
║                                         ║
║ 🟡 SEVERITY: MEDIUM                     ║
║  • Till-recon missing Wed/Thu          ║
║    → Add via /m form                    ║
║                                         ║
║  • 18 invoices needs-review             ║
║    → Triage                             ║
║                                         ║
║ INTER-ENTITY OWINGS                     ║
║  ART → ARE  £2,300 net (90d)           ║
║  → Settle via transfer                  ║
╚═════════════════════════════════════════╝
```

### Work · More

A list of every sub-surface for the long tail, with last-data-touched timestamps:

```
TouchOffice            data 4m ago    →
Dojo                   1d ago         →
Caterbook              today          →
Workforce (detail)     today          →
GP roll-up             today          →
Recipes & consumption  today          →
Accommodation pricing  today          →
Spend by category      live           →
Top vendors            live           →
Inter-entity ledger    live           →
Credit cards           live           →
```

### Private · Today (Mobile)

```
╔═════════════════════════════════════════╗
║ TODAY · PRIVATE                         ║
╠═════════════════════════════════════════╣
║  ● Net worth     £1.485M  ▼ £-47k MoM  ║
║  ╰─ property £2.20M − debt £697k        ║
║                                         ║
║  ● Cash position −£12,236   ⚠ overdrawn ║
║  ╰─ ARE +£5,264  Personal −£14,7k       ║
║                                         ║
║  ● Mortgage payment due  £2,264         ║
║  ╰─ 1 day (16 May, 295905-02)          ║
║                                         ║
║  ● Cards balance £22,006                ║
║  ╰─ next statement 28 May               ║
╚═════════════════════════════════════════╝

──────── UPCOMING ─────────────────────────
  Tomorrow  Mortgage DD £2,264
  Mon 19    School term begins
  Wed 21    Edith dentist 16:00
──────────────────────────────────────────

──────── ALERTS ───────────────────────────
  🟠 1 MOT due in 60d (WF14FNP)
  🟡 4 mortgage statements missing
  🟢 All children's school fees paid
──────────────────────────────────────────
```

### Private · Family (Mobile)

```
╔═════════════════════════════════════════╗
║ FAMILY                                  ║
╠═════════════════════════════════════════╣
║ CHILDREN                                ║
║  Edith     age 9   Trythall School      ║
║  ─── next event: dentist 21 May        ║
║  Mae       age 11  Trythall School      ║
║  ─── next event: ballet, Thursday      ║
║  Lily      age 14  Mounts Bay Academy   ║
║  ─── next event: school photos 23 May  ║
║                                         ║
║ CALENDAR (7d)                           ║
║  [mini agenda with school + medical    ║
║   events colour-coded per child]       ║
║                                         ║
║ MEDICAL                                 ║
║  No outstanding follow-ups              ║
╚═════════════════════════════════════════╝
```

### Build · Pipelines

```
╔═════════════════════════════════════════╗
║ BUILD · PIPELINES                       ║
╠═════════════════════════════════════════╣
║ SERVICES (7)                            ║
║  bot-responder        ● ok    1h ago    ║
║  invoice-pipeline     ● ok    1d        ║
║  paperless-ingest     ● ok    5m        ║
║  touchoffice-scraper  ● ok    4m        ║
║  dojo-staging         ● ok    1d        ║
║  critical-listener    ● ok    queue 0   ║
║  till-reconciliation  ● ok    1d        ║
║                                         ║
║ CRON SCHEDULE                           ║
║  [Gantt-style strip: which scripts     ║
║   ran in the last 24h, success/fail]   ║
║                                         ║
║ INGEST PIPELINE FLOW                    ║
║  email   ──▶ queue ──▶ classify ──▶ DB  ║
║  scan    ──▶ Paperless ──▶ webhook     ║
║   ╰── 5 in past 24h                     ║
║                                         ║
║ HEARTBEAT                               ║
║  TouchOffice  4m   ● live              ║
║  Tanda sync   7h   ● synced            ║
║  Dojo         1d   ● lagging  ⚠         ║
╚═════════════════════════════════════════╝
```

### Build · Models

```
╔═════════════════════════════════════════╗
║ BUILD · MODELS                          ║
╠═════════════════════════════════════════╣
║ SPEND (rolling 30d)                     ║
║  £42.18  ▼ -£5 vs prev 30d              ║
║  ─── per-model breakdown ───            ║
║   Haiku 4.5      £28.10  67%            ║
║   Sonnet 4.6     £12.04  29%            ║
║   Opus 4.7        £2.04   5%            ║
║                                         ║
║ TOKENS (24h)                            ║
║  in  4.2M    out 612k                   ║
║  [sparkline of daily tokens]           ║
║                                         ║
║ DRIFT                                   ║
║  3 metrics drifting outside band:       ║
║   • email-classifier P50 latency        ║
║   • invoice-extractor accuracy ▼        ║
║   • bot-responder Telegram lag          ║
║                                         ║
║ BENCHMARK LEADERBOARD                   ║
║  [top 5 models by composite score]     ║
║                                         ║
║ WORKER VRAM (Ollama)                    ║
║  [stacked bar: which model is loaded]  ║
╚═════════════════════════════════════════╝
```

### Build · Forensics

```
╔═════════════════════════════════════════╗
║ BUILD · FORENSICS                       ║
╠═════════════════════════════════════════╣
║ DEAD-LETTER QUEUE                       ║
║  3 events stuck                         ║
║   • email.received   2d ago   → inspect ║
║   • document.received 1d      → inspect ║
║   • email.classified 5d       → inspect ║
║                                         ║
║ RECENT ERRORS (24h)                     ║
║  [time-bucketed bar chart of errors    ║
║   by service]                           ║
║                                         ║
║ ANOMALIES                               ║
║  • TouchOffice plu_sales count z=-2.4   ║
║    (likely scrape miss)                ║
║  • Bot-responder reply rate z=+1.9      ║
║                                         ║
║ DREAMING                                ║
║  Nightly heuristic generator ran 03:15  ║
║  3 hypotheses generated                ║
║   → review                              ║
╚═════════════════════════════════════════╝
```

### All · Sitemap

```
╔═════════════════════════════════════════╗
║ ALL · search every page                 ║
╠═════════════════════════════════════════╣
║ 🔍 [_______________________________]   ║
║   ▼  filter:  Pages • Slugs • Views    ║
║                                         ║
║ PAGES (23)                              ║
║  /work/today                last live   ║
║  /work/staff                            ║
║  /private/today             last live   ║
║  /private/family                        ║
║  /build/pipelines           1m ago      ║
║  /finance                   live        ║
║  /workforce                 today       ║
║  /vehicles                  3h          ║
║  /touchoffice               4m          ║
║  /dojo                      1d          ║
║  /caterbook                 today       ║
║  /invoices                  live        ║
║  /invoices/needs-review     live        ║
║  /reconciliation            live        ║
║  /recon                     live        ║
║  /documents                 5m          ║
║  /economics                 today       ║
║  /tasks                     today       ║
║  /agents-ops                live        ║
║  /forensics                 1d          ║
║  /research                  —           ║
║  /search                    n/a         ║
║  /coverage                  today       ║
║                                         ║
║ SLUGS (17 approved finance + 8 ops)    ║
║  account_balances                       ║
║  capital_summary                        ║
║  credit_card_status                     ║
║  ... (full list, click to run)          ║
║                                         ║
║ VIEWS (db, ~60)                         ║
║  v_account_balances_now                 ║
║  v_capital_summary                      ║
║  v_mortgage_summary                     ║
║  ... (filtered list, click → table)     ║
╚═════════════════════════════════════════╝
```

---

## Visualisation library — what to add

> The current dashboard is heavy on tables and KPI tiles. These add narrative + at-a-glance signal.

| Visualisation | Where it lives | Why |
|---|---|---|
| **Traffic-light tile with sparkline** | Today (Work + Private) — main KPIs | Status colour + 14d trendline below the headline number. Single component reused everywhere. |
| **Activity heatmap** (day × hour) | Work · Staff, Work · More · TouchOffice | Show when sales/staff hours land. Reveals understaffed peaks + overstaffed troughs. |
| **Waterfall chart** | Private · Today (net worth MoM), Work · More · GP | Visualise +/- contributions to a delta. Better than a single number for "why did this move". |
| **Sankey diagram** | Work · Actions · Inter-entity owings | Money flow between entities and accounts. Reveals which entity is subsidising which. |
| **Calendar strip** | Private · Today, Private · Family, Actions tabs | 30-day forward look at obligations: mortgage DDs, MOT/insurance, school events, VAT/PAYE due dates. Single horizontal row, colour-coded per category. |
| **Anomaly chip** | Every KPI tile | Small "z=+1.8" badge if the value is outside its 2σ band. Already have the data via `v_kpi_anomalies`. |
| **Gantt strip for cron** | Build · Pipelines | Last 24h of cron runs, success/fail colouring, time-aligned. Faster than reading log files. |
| **Stacked bar — VRAM/tokens by model** | Build · Models | Which model is parked in memory + which is burning tokens. |
| **Mini-pie ring for budget burn** | Build · Models · Spend | 30d spend vs intuited monthly cap. Quick "are we trending hot" read. |
| **Coverage heatmap (quarters × loans)** | Private · Docs · Mortgages | The U79 statement-coverage matrix as a visual. Red cells = missing. Click to drill. |
| **Geo dot map** | (optional) Property tab | If we want to show where the freeholds are. Probably overkill given 5 properties. |

---

## CTA framework

A short list of action verbs the UI uses consistently, so Jo never has to learn a new word for the same thing.

| Verb | Meaning | Used on |
|---|---|---|
| **Resolve** | mark a flagged exception as handled, with a note | Actions tab exceptions, recon flags, dead-letters |
| **Triage** | go to a list view to bulk-process | Invoices needs-review, classifier queue |
| **Scan** | drop a paper doc to OCR | Mortgage gaps, missing receipts, vehicle docs |
| **Confirm** | apply a model decision the AI is unsure about | Classifier queue, classification queue |
| **Snooze** | push to future (don't surface for N days) | Tasks, action queue, invoice review |
| **Settle** | initiate an inter-entity transfer | Owings, credit-card payment due |
| **Investigate** | open a deep-dive on a single record | Ghost shifts, recon mismatches, dead-letters |
| **Ask** | natural-language query on the data | Every page header has the global Ask box |

Every CTA is a button or link with one of these verbs. Avoid synonyms ("review", "look at", "check") — they're noise.

---

## New endpoints / slugs to add

Plain SQL views + slugs (no migration drama). All built on existing tables.

| Slug | View name | Powers |
|---|---|---|
| `today_kpis_work` | `v_today_kpis_work` | Work Today tile row: labour %, takings, GP, bookings, cash on hand |
| `today_kpis_private` | `v_today_kpis_private` | Private Today: net worth, cash, mortgage due, cards |
| `action_queue` | `v_action_queue` | Unified open-action feed (recon flags, ghost shifts, missing tills, needs-review invoices) with severity |
| `email_kpis_work` | `v_email_kpis_work` | Inbox count, new since LW, classifier-uncertain count |
| `docs_kpis_work` | `v_docs_kpis_work` | Invoice statuses, contracts expiring, compliance dates |
| `family_kpis` | `v_family_kpis` | Per-child upcoming events, ages, school metadata |
| `upcoming_obligations` | `v_upcoming_obligations` | 30d forward calendar of bills, DDs, MOT/insurance, school events |
| `build_pipeline_status` | `v_build_pipeline_status` | Service health + cron run history (24h Gantt data) |
| `model_spend_30d` | `v_model_spend_30d` | Per-model token + cost rollup |
| `forensic_summary` | `v_forensic_summary` | DLQ depth, recent errors by service, drift count |
| `sitemap` | (no view; main.py introspects `app.routes`) | The All page |
| `kpi_anomalies` | already exists | Drives the anomaly chips |

All slugs follow existing pattern in `main.py:4854-4866` — add to `_load_finance_slugs` whitelist + insert into `query_whitelist` table.

---

## Implementation plan (phases)

### Phase 1 — Header + realm toggle (~3h)

1. Create `services/build-dashboard/static/_components/header.html` partial — a server-side include that every page references.
2. New JS module `static/_components/realm-toggle.js`:
   - Reads `localStorage.homeai.realm`
   - Adds a `fetch` interceptor that injects `X-Realm` header
   - Reloads (or hot-swaps) on toggle change
3. Patch every existing page to include the partial. Initially `<script src="/static/_components/realm-toggle.js"></script>` injected at body close.
4. Verification: load `/finance` with localStorage realm=family, confirm `v_account_balances_now` returns only family-realm accounts.

### Phase 2 — Work + Private "Today" pages (~6h)

1. New routes in main.py: `/work/today` `/private/today`. Each serves a new `today-work.html` / `today-private.html`.
2. New endpoints/views (`today_kpis_work`, `today_kpis_private`, `action_queue`, `upcoming_obligations`).
3. New shared Alpine component `kpi-tile.js` with sparkline support (extend the existing `traffic-light` tile pattern from `m.html`).
4. Reuse existing `/api/m/mobile` data + extend with the new slugs.

### Phase 3 — Work tabs (Staff/Email/Docs/Actions/More) (~8h)

1. Lift content from existing `/workforce`, `/invoices`, `/reconciliation`, `/economics`, `/dojo`, `/touchoffice` into the new IA, served at `/work/<tab>`.
2. The old URLs continue to work (301 redirects to the new IA) — no breakage for bookmarks / cron jobs that hit `/api/*`.
3. Action queue page — new view `v_action_queue` unions:
   - `mart.exceptions` (severity ≥ medium, status='open')
   - `vendor_invoice_inbox` (status='needs_review')
   - `bot_instructions` (status='pending', lane='query')
   - `v_documents_expiry_due` (within 60d)

### Phase 4 — Private tabs (Today/Family/Email/Docs/Actions) (~5h)

Same shape as Work. `/private/today` re-uses `/finance` data but presents it as a tile dashboard rather than a multi-tab account viewer. `/private/family` is new — pulls from `children`, `child_events`, `medical_history`, `v_calendar_upcoming`.

### Phase 5 — Build hub (~4h)

1. `/build/pipelines` — existing `/agents-ops` content + new cron Gantt
2. `/build/models` — pull from `ai_usage`, `benchmark_results`, `v_ai_calls_by_realm`. New stacked-bar VRAM viz
3. `/build/forensics` — existing `/forensics` + drift/anomaly summary
4. `/build/spec` — render `SPEC.md` (markdown → HTML) plus a list of decisions in `.claude/decisions/`
5. `/build/sovereignty` — current `/index` sovereignty + lifecycle + context-pressure tiles

### Phase 6 — All / Sitemap (~3h)

1. `/all` — server iterates `app.routes` to enumerate every page; query_whitelist for slugs; `information_schema.views` for v_* views in `public` + `mart` schemas.
2. Each row shows last-data-touched timestamp (where derivable from underlying tables).
3. Global search bar uses `pg_trgm` over: page paths, slug names, view names, recent doc titles, recent invoice subjects.

### Phase 7 — Polish & decommission (~3h)

1. Old `/index` becomes a redirect to `/work/today` (or `/private/today` based on realm).
2. Update `Caddyfile` + `Authelia` ACL so `/build/*` and `/all/*` are owner-only.
3. Add nav-link telemetry to `audit_log` so we see which surfaces actually get used.
4. Delete genuinely-unused pages (`playground.html`, `landing.html`, `pub.html` if confirmed dead).

**Total estimated effort: ~32h** across 7 phases.

---

## Handoff brief — for Gemini or any other AI tool

> If you're picking this plan up cold, here's what you need to know to ship it without re-litigating decisions.

### Project context
- Codebase: `/home_ai/`. The dashboard is a FastAPI app in `/home_ai/services/build-dashboard/main.py` (~5,000 LOC) plus 23 HTML pages in `/home_ai/services/build-dashboard/static/`.
- Built with FastAPI + Alpine.js + Tailwind (CDN) + Tabulator (CDN). No build step — static HTML served direct.
- Auth: Authelia + Caddy forward_auth. Realm enforced server-side via `X-Realm` header read in `main.py:497-529`. Three realms: `owner`, `work`, `family`.
- Data: PostgreSQL `homeai` db, 60+ tables/views across `public`, `mart`, `raw`, `staging` schemas. RLS enforced per realm.
- The "slug" pattern (`/api/finance/slug/{slug}`) is the safe way to add a query without writing endpoint code — define SQL in `query_whitelist` and add slug name to `_load_finance_slugs` allowlist in `main.py:4854-4866`.

### Conventions to follow
- Match the existing dark-glassmorphic palette (`.glass`, `.tile`, `.mono`, `.pos`, `.neg`, traffic-light `tl-green/amber/red`).
- Alpine pattern: every page exports `window.<module>()` returning a reactive object with `boot()` method, used via `x-data="<module>()" x-init="boot()"`.
- Date window picker is a shared component (`u45-components.js`) emitting `@date-window-changed.window` events.
- Server-side filters: every endpoint sets `SET app.current_entity` and calls `home_ai.set_realm($1)` from the X-Realm header.
- Mortgage parser is in `_parse_principality_statements()` in `main.py:2810-2864` — reuse if extending.

### What NOT to do
- Don't create new top-level URLs that bypass the realm middleware.
- Don't add raw SQL to endpoints — use the slug pattern.
- Don't introduce a new CSS framework or JS build system. CDN-only.
- Don't change the dark theme. Two themes is two times the work.
- Don't remove old URLs without 301 redirects — there are cron jobs and Tampermonkey scripts hitting them.

### Critical files to read first
| File | Why |
|---|---|
| `/home_ai/services/build-dashboard/main.py` | The whole app. Especially lines 497-529 (realm middleware), 4854-4866 (slug allowlist), 2810-2864 (statement parser) |
| `/home_ai/services/build-dashboard/static/m.html` | The mobile design language — the new Today views inherit this |
| `/home_ai/services/build-dashboard/static/finance.html` | The KPI banner + tab pattern this plan extends |
| `/home_ai/services/build-dashboard/static/agents-ops.html` | The shape Build · Pipelines inherits |
| `/home_ai/SPEC.md` | Source of truth for the data model + pipelines |
| `/home_ai/postgres/migrations/V97_*.sql` and `V99_*.sql` | Examples of view + slug pattern for finance data |

### How to test the result end-to-end
1. `curl -H 'X-Realm: work' http://localhost:8090/api/finance/slug/today_kpis_work` should return non-empty rows for active business KPIs.
2. Load `/work/today` in a browser via the Authelia-protected URL. The realm chip in header should read "Work" in amber.
3. Click the segmented control → "Private". Page should hot-swap to private data without a full reload.
4. Open `/build/pipelines` — should show all 7 services with current health from the `services` view.
5. Open `/all`, type "mortgage" — should return matching pages (`/private/docs`, `/finance#mortgages`) + slugs (`mortgages_all`, `mortgage_coverage`) + views (`v_mortgage_summary`).
6. Confirm old `/finance` still works (301 to `/work/finance` or `/private/finance` based on realm).

---

## Notifications (post plan-mode)

When this plan is approved + executed, three notifications happen:

1. **Telegram on plan approval** — short message: "U84 UX restructure approved. Phase 1 (realm toggle) starting; ETA 3h."
2. **Email at end of each phase** — sent to `jolyon.sandercock@gmail.com` with: phase name, what shipped, screenshots (Playwright captures), what's still pending.
3. **Final email at ship** — full before/after wireframes, list of decommissioned URLs, and links to each new tab.

The email body for each update is markdown-rendered HTML using the existing `/send/bot` endpoint pattern (see `bot-responder/responder.py:43-50` for the `tg_send` / `email_reply` helpers).

---

## Verification — how Jo knows it's right

After full implementation, these read-only checks should pass:

1. **Realm switch works:**
   ```bash
   # Same URL, different realm header → different data
   curl -sH 'X-Realm: work'   http://localhost:8090/api/today_kpis | jq .takings
   curl -sH 'X-Realm: family' http://localhost:8090/api/today_kpis | jq .takings
   ```
2. **Every old URL 301s correctly:**
   ```bash
   for u in /finance /workforce /vehicles /m /dojo /touchoffice; do
     curl -sI http://localhost:8090$u | grep -i 'location\|301'
   done
   ```
3. **Sitemap enumerates every route:**
   ```bash
   curl -s http://localhost:8090/api/all/sitemap | jq 'length'
   # expect ≥ 23
   ```
4. **No old endpoint is unreachable** — run `u75-pipeline-smoke.sh` plus a new `u83-route-smoke.sh` that hits every route from the IA and confirms 200/302.
5. **Mobile usability:** Playwright script loads each Today/Staff/Email/Docs/Actions page at 375px viewport, checks all interactive elements are >44px tap target.

---

## Open questions to revisit during execution

- **Realm-switch when there's unsaved input** — should the toggle confirm before discarding (e.g. a half-typed manager note)? Probably yes; add a `dirty` guard.
- **Action-queue prioritisation logic** — severity + age + £ exposure? Or pure severity? Empirically tune after 2 weeks of use.
- **Cron Gantt** — fetch from `audit_log` action='cron-tick' or shell out to a small `crontab -l` parser endpoint? Audit_log is cleaner but only covers cron jobs that explicitly log. Start with audit_log; backfill any non-logging crons.
- **/build/spec rendering** — markdown-it server-side or just `<iframe>` a static render? Server-side preferred (search becomes easy).
- **Decommissioning `/playground` `/landing` `/pub`** — confirm these aren't used by an external scraper before deleting.

---

## End of plan
