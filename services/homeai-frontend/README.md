# homeai-frontend

Next.js 14 App Router operational dashboard for The Olde Malthouse Inn. Industrial-hospitality aesthetic — dark base, amber accents, Geist Mono for data, mobile-first.

## Status

Built overnight per `HOMEAI-DASHBOARD-FRONTEND-SPRINT.md`. All 11 pages compile and render with live data where available, `PlaceholderState` everywhere a data source isn't wired yet.

Running locally at `http://localhost:3003` (Docker compose service `homeai-frontend`).

## Pages

| Path | What | Data sources |
|---|---|---|
| `/` | Dashboard | `frontend_today_gross`, `frontend_wage_pct_summary`, `frontend_seven_day_strip`, `frontend_accommodation_today` |
| `/sales` | Sales | `frontend_today_gross` + date picker shell (per-day slug pending) |
| `/rooms` | Rooms grid + click-modal | `frontend_rooms_today`, `frontend_accommodation_today` |
| `/restaurant` | Run sheet | `frontend_restaurant_today` |
| `/bar` | Pub KPIs + wage % | `frontend_today_gross`, `frontend_wage_pct_summary` |
| `/cafe` | Café KPIs | `frontend_today_gross` |
| `/staff` | Staff + wage % | `frontend_wage_pct_summary`. Live roster pending Tanda |
| `/comms` | Reviews + email + WA | Placeholders pending OAuth + WA pairing |
| `/tasks` | Action queue | `frontend_action_queue` |
| `/admin` | Invoices + compliance | `frontend_invoices_recent`, `obligations_upcoming` |
| `/backend` | Cache + system health | `ai_cache_effectiveness` |

## Sandbox mode

Click the `Edit` button (top right). Every page section becomes draggable + comment-able. Comments save to `sandbox_comments` table via `POST /api/sandbox/comments`. Re-click to leave edit mode.

## Local dev

```bash
docker compose up -d homeai-frontend
# Then open http://localhost:3003
```

To run without Docker:
```bash
cd /home_ai/services/homeai-frontend
cp env.example.txt .env.local         # set POSTGRES_READONLY_URL
npm install
npm run dev
```

## Vercel deploy

```bash
./deploy.sh
```

Reads Vercel creds from Vault at `secret/vercel`. If not present, prints what to set and exits cleanly.

Set creds:
```bash
docker exec -e VAULT_TOKEN=$VAULT_TOKEN homeai-vault vault kv put secret/vercel \
  token=YOUR_TOKEN org_id=team_xxxx project_id=prj_xxxx
```

## Wix access-controlled hosting

See `docs/wix-migration.md`. Architecture: Wix Members → Velo HMAC handoff → Next.js middleware validates → role-scoped page access.

`docs/velo-homeai-handoff.web.js` — Velo backend module ready to paste into Wix Studio.

## Architecture

- **Framework**: Next.js 14 App Router, TypeScript
- **Styling**: Tailwind CSS (custom theme in `tailwind.config.js`)
- **Charts**: Recharts
- **Data fetching**: TanStack React Query
- **Drag-and-drop** (sandbox only): @dnd-kit/core
- **Database**: pg → `homeai_readonly` Postgres role with realm RLS

## Adding a new page

1. Define a new whitelist slug in `query_whitelist` (or reuse).
2. Add the route under `app/<page>/page.tsx`.
3. Wrap each section in `<SandboxWrapper id="<page>.<section>" />` so it's draggable + comment-able.
4. Use `useSlug<T>('your_slug')` to fetch data.
5. Add to nav in `components/shell/nav.ts`.

## Extending the API

`/api/slug/[slug]` is the generic surface — any slug in `query_whitelist` is callable. To skip the whitelist for one-off pages, write a dedicated route under `app/api/...`.

`POST /api/sandbox/comments` and `GET /api/sandbox/comments?component_id=…` are the sandbox storage.

## UI design rules (from the 2026-06-11 snag audit — 73 snags reviewed)

1. **Drill-down first.** Every aggregate number links to its evidence rows
   (invoice list, email, transactions). 15 of 73 snags were this ask. Links
   must carry filters in the URL AND the target must read them
   (`/app/invoices?department=…` pattern — see urlParam() in invoices/page.tsx).
2. **Freshness badges on scrape-fed sections.** Use
   `<FreshnessBadge source="touchoffice|caterbook|workforce|reviews|weather|emails|invoices|bank"/>`
   in the Section `action` slot. Backed by the `data_freshness` slug.
3. **Honest empty states.** A widget that CANNOT have data (blocked
   integration, unused flow) must say why — set `query_whitelist.empty_state_md`
   and/or a specific PlaceholderState message. Never render a permanently
   blank/zero widget as if it were loading.
4. **Tables: 10 visible rows** then scroll; filter/sort on anything Jo scans.
5. **No CTAs in Jo's read-path** unless input is genuinely required (snag #54).
6. **Submit buttons: disable in flight + explicit success state** (duplicate
   snags came from missing feedback).
