# U31 — Dashboard tables UX (sort + filter + click-through)

**Goal:** Every data table on the dashboard becomes sortable by clicking
column headers, filterable per-column with a free-text input, and every
row links to its source — the original email, the scraped HTML
snapshot, the PDF attachment, or the upstream vendor page.

After U31, you can answer "where did that figure come from?" in one
click from any row on any page.

## Scope — every table on every dashboard page

| Page | Tables to upgrade | Click-through target |
|---|---|---|
| `/touchoffice` | per-day, top-depts, top-plus, recent scrapes | scrape snapshot HTML/PNG; touchoffice.net for live drill-down |
| `/caterbook` | arrivals/stayovers/departures, per-room revenue, daily snapshots, recent imports | source Gmail message; raw PDF; per-guest history page |
| `/invoices` | inbox, by-vendor | source Gmail message; PDF preview; vendor's email thread |
| `/workforce` | per-day, per-dept, top-staff, recent sync | my.workforce.com user page; sync-log error detail |
| `/pub` | (already uses old EPoS tables — this sprint rewires it to the new schema as a side effect) | same as /touchoffice + /caterbook |
| `/` Mission Control | debt, tasks, agents, recent events, leaderboard | linked source for each (n8n workflow URL, debt sprint plan, etc.) |

## Architecture

### Why a library

We have 12+ raw `<table>` blocks across 5 pages. Adding sort + filter
to each one by hand in Alpine is ≈1 day of bespoke fiddly work and an
inconsistent UX. A small library standardises it.

**Pick: Tabulator** (https://tabulator.info)
- MIT, ~50KB minified+gzipped, no jQuery
- Native sort, filter, column-resize, mobile-responsive built-in
- Drops into a `<div id="…">` — Alpine still owns data loading; Tabulator owns rendering
- Theme works in both light and dark; matches the existing glassmorphism palette
- Click-row + per-cell click handlers built-in

Alternatives considered:
- AG Grid Community — heavier (~500KB), more features than we need
- DataTables — jQuery dependency, we'd be the only page using jQuery
- Roll-our-own Alpine — sortable in a day, filterable in another, mobile-responsive in another. Not worth it.

### New endpoints needed on `build-dashboard`

| Route | Purpose |
|---|---|
| `GET /viewer/email/{account}/{message_id}` | Renders the email's plain-text + html body inline (fetched live via google-fetch). Page has links to "view in Gmail" + "download original" |
| `GET /viewer/pdf/{path}` | Streams a PDF from `/home_ai/storage/scraper-debug/**` (whitelist of paths only — no traversal) |
| `GET /viewer/snapshot/{filename}` | Streams an HTML or PNG snapshot from the same dir, for scrape-debug click-through |
| `GET /viewer/touchoffice-report` | Opens a new tab pointed at `https://www.touchoffice.net/reports_engine/report_view` — user is already logged in via browser session |

These are all read-only and Tailscale-fenced (the dashboard already binds
on `ai-internal` + `ai-monitoring`, so only tailnet hosts see them).

### Shared JS helper

```
/home_ai/services/build-dashboard/static/js/homeai-table.js
```

Exposes `homeai_table(containerEl, data, config)` that wraps Tabulator
with project defaults:
- column-header sort enabled on every column
- per-column inline filter input below the header
- row-click handler resolved from `config.row_link(row)`
- glassmorphism dark theme tokens
- responsive collapse on narrow viewports

Each page goes from ≈100 lines of `<template x-for>` per table to ~10
lines of `homeai_table(...)` per table.

## Chunks

| # | Chunk | Cost | Owner |
|---|---|---|---|
| 1 | Add Tabulator CDN + dark-theme overrides to dashboard `static/css/tables.css` | 20 min | me |
| 2 | Write `homeai-table.js` helper with project defaults + click-link resolver | 45 min | me |
| 3 | New `/viewer/email/{account}/{message_id}` endpoint — fetches via google-fetch, sanitises HTML (DOMPurify), renders inline | 60 min | me |
| 4 | New `/viewer/pdf/{path}` + `/viewer/snapshot/{filename}` — path-whitelist enforced, range-request support for PDF | 40 min | me |
| 5 | Migrate `/touchoffice` — 4 tables, link recent_scrapes rows → snapshot viewer | 30 min | me |
| 6 | Migrate `/caterbook` — 4 tables, link arrivals/stayovers/departures rows → email viewer, room_nights rows → guest-history page | 40 min | me |
| 7 | Migrate `/invoices` — 2 tables, link subject → email viewer, PDF column → pdf viewer, vendor column → vendor filter | 30 min | me |
| 8 | Migrate `/workforce` — 4 tables, link top_staff rows → my.workforce.com user URL, recent_sync error rows → expand-on-click | 30 min | me |
| 9 | Migrate `/` Mission Control tables — debt + tasks + agents — also pick up the queued "traffic-light + paginated" refactor pieces from memory `project_dashboard_refactor.md` | 90 min | me |
| 10 | Mobile audit — every page on a phone-sized viewport (375×812), Tabulator's responsive collapse on each | 30 min | me |
| 11 | Empty + loading + error states across all pages | 20 min | me |

**Total:** ~7h me, 0 user.

## Click-through map

### `/touchoffice`
- **per-day row** → opens `/touchoffice/day/<site>/<date>` (new page) showing
  that day's full widget detail (already in DB, just needs render)
- **recent scrape row** → opens `/viewer/snapshot/<filename>.html` (the
  saved page state) or `.png` (the screenshot)
- **top dept / top PLU** → filters the per-day table to days where this
  dept/PLU appears (chain-filter behaviour)

### `/caterbook`
- **arrivals / stayovers / departures cell** (guest name) →
  `/viewer/email/info/<message_id>` showing the source email + the PDF
  attachment inline
- **room_nights row** → `/caterbook/booking/<ref>` showing the full
  collated booking (all observations across days)
- **recent imports row** → `/viewer/email/<account>/<source_email_id>`
- **room column** → chain-filter all tables to that room

### `/invoices`
- **subject cell** → `/viewer/email/info/<source_email_id>` showing the
  email body and PDF
- **vendor cell** → chain-filter (this page) + crosslink to a future
  `/vendors/<domain>` page (deferred)
- **PDF column** → `/viewer/pdf/<first_attachment_path>` (when populated
  by P2 enrichment in a later sprint)
- **linked_invoice_id** → `/invoices/<id>` deep detail page (deferred)

### `/workforce`
- **top_staff row** (user) → opens
  `https://my.workforce.com/users/<external_id>` in a new tab
- **recent_sync error row** → expand inline to show full error message
- **per_day row** → filter all tables to that day
- **department row** → filter all tables to that department

### `/` Mission Control
- **debt item** → opens its referenced sprint plan in `/sprints/<name>`
- **task item** → expands inline; if `pipeline` set, links to n8n
  workflow URL (already in current code, just keep it through the
  migration)
- **agent row** → opens agent log/decisions
- **recent event row** → expand inline showing the event payload (already
  HMAC-verified upstream)

## Cross-cutting features (every table gets these)

- **Header sort:** click once → asc, click twice → desc, click thrice → off. Multi-sort via shift-click
- **Per-column filter:** small input below the header, debounced 200ms.
  Numeric columns support `>100`, `<50`, `=0`, `between(a, b)`
- **Free-text search:** single search box at top of each table searches
  across all visible columns
- **Visible-column picker:** menu icon next to search opens a list of
  columns the user can show/hide. Layout persists in localStorage
- **Export:** "Export visible" button on each table → CSV download
  matching the current sort + filter + visible columns
- **Pagination:** 50 rows/page default. "Load all" toggle stays in
  localStorage. Server-side paging deferred — most tables are <2k rows
- **Keyboard:**
  - `/` focuses the page's search
  - `Esc` clears the focused filter
  - `j` / `k` selects next / prev row
  - `Enter` opens the row's link target

## Visual + responsive

- Dark glassmorphism palette unchanged; Tabulator gets a custom theme
  derived from the existing CSS variables
- `font-variant-numeric: tabular-nums` on every numeric column (no
  digit jitter on filter/refresh)
- Mobile collapse: each Tabulator table switches to a card view at
  `<640px` — primary column on first line, others as `label: value`
  pairs underneath
- Click-through targets open in a new tab (`target="_blank" rel="noopener"`)
  so the user keeps their dashboard state

## Security checkpoints

- `/viewer/pdf/{path}` and `/viewer/snapshot/{filename}` enforce a strict
  path allow-list — only paths under `/home_ai/storage/scraper-debug/`
  and `/home_ai/storage/caterbook-samples/` (etc.) are served. Anything
  else → 404. No `..` traversal possible (path normalised + checked
  against the prefix)
- `/viewer/email/*` runs the fetched HTML through DOMPurify before
  rendering. Email bodies can contain anything; treating them as plain
  text + sanitised HTML is the only safe path
- Dashboard is already on `ai-internal` + `ai-monitoring` networks
  (Tailscale-only, no public binding). U31 doesn't change that

## Acceptance

- [ ] Every table on every page is sortable by clicking column headers
- [ ] Every table on every page has per-column filtering
- [ ] At least one click-through path works on each of /touchoffice,
      /caterbook, /invoices, /workforce
- [ ] /caterbook arrivals row click opens the source email body inline
      from the dashboard (not a Gmail web redirect)
- [ ] /invoices subject click opens the source email inline
- [ ] /touchoffice recent_scrapes row click renders the saved HTML
      snapshot
- [ ] Every table on a phone-sized viewport (375px) is usable — no
      horizontal scroll on the page wrapper, card-collapse on the table
- [ ] All viewer endpoints reject path traversal attempts (covered by
      unit test in `tests/test_viewer_routes.py`)
- [ ] Layout preferences (visible columns, page size) persist in
      localStorage across browser sessions

## What carries forward to U32

- Server-side pagination for tables that grow >5k rows (currently only
  workforce_shifts is in that range)
- Cross-table linking — e.g. clicking a touchoffice PLU shows all
  Caterbook days where the same room generated comparable revenue
- The full "Dashboard Refactor" tiered hierarchy from memory
  `project_dashboard_refactor.md` — top-tier phase-gate progress bar,
  middle-tier live ops, bottom-tier registries. U31's table-by-table
  click-through is foundational; the broader refactor reuses it
- Vendor detail page `/vendors/<domain>` with all invoices grouped +
  spend trend
- Guest history page `/caterbook/guest/<name>` showing repeat-stay
  patterns
