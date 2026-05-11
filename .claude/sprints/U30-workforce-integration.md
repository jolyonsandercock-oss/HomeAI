# U30 — Workforce.com (Tanda) integration

**Goal:** Import staff cost, timesheets, labour hours, scheduled vs actual,
and the sales data Workforce already pulls from TouchOffice — so we can
join labour ↔ revenue per shift / day / week in the same Postgres.

**API:** `https://my.workforce.com/api/v2/*` — OAuth2 (password flow ✓
simpler for single tenant), 200 req/min/requester, `updated_after`
incremental sync available, webhooks supported (defer to U31).

## Why this fits the existing build

We already have **TouchOffice flowing into Workforce** on the user's side
(sales totals are pushed from the till). Workforce then attaches them to
shifts. Pulling the *Workforce* view gives us:

- staff cost per shift (already calculated by Workforce — no rate maths
  on our side)
- `wage_comparisons` — Workforce's own labour-pct readout (scheduled
  cost / actual cost / sales actual / sales target), ready-made for the
  labour-pct widget
- payroll-line truth that's independent of our own EPoS scrape

Two truth sources for sales (TouchOffice direct + Workforce mirror) is a
free integrity check.

## Schema (V29 migration — already applied)

Six tables, RLS-protected, mirror the API shape:

| Table | Source endpoint | Purpose |
|---|---|---|
| `workforce_users`            | GET /api/v2/users           | staff register |
| `workforce_locations`        | GET /api/v2/locations       | site mapping |
| `workforce_shifts`           | GET /api/v2/shifts?from=…&to=… | per-shift cost + hours |
| `workforce_timesheets`       | GET /api/v2/timesheets/…    | per-period total |
| `workforce_wage_comparisons` | GET /api/v2/wage_comparisons | labour-pct + sales actual/target |
| `workforce_sync_log`         | —                            | per-call status + runtime |

Each row keeps the full API response in a `raw_payload` jsonb so future
fields can be back-filled without re-syncing.

## Sync architecture

```
                                           ┌─────────────────────────┐
[cron 02:30 daily]                         │ workforce_sync_log      │
   │                                       └────────▲────────────────┘
   ▼                                                │
[scripts/u29-workforce-sync.sh DAYS=2] ─────────────┤ (one log row per
   │   reads secret/workforce from Vault            │  endpoint call)
   │   bearer token + 200/min ceiling               │
   ▼                                                │
[homeai-playwright container, async asyncpg + httpx]│
   │                                                │
   ├─ GET /users          → upsert workforce_users ─┤
   ├─ GET /locations      → upsert workforce_locations
   ├─ GET /shifts?from=… → upsert workforce_shifts
   ├─ GET /timesheets/…  → upsert workforce_timesheets
   └─ GET /wage_comparisons → upsert workforce_wage_comparisons

   incremental: since the API supports updated_after, after the initial
   backfill the daily cron passes from=yesterday only — keeps under 50
   reqs/run, well within rate limits.
```

**Idempotent:** every UPSERT keys on `external_id` (Tanda's stable id).
Re-syncing the same range is a no-op except for `last_synced_at`.

## Build chunks (when creds land tomorrow)

| # | Chunk | Cost | Notes |
|---|---|---|---|
| 1 | Run `scripts/u29-workforce-creds.sh`, paste long-lived access token | 5 min, you | docs at https://my.workforce.com/api/oauth/access_tokens |
| 2 | First-pass sync: `./scripts/u29-workforce-sync.sh 365` | 5 min, me-via-cron | full year, ~50 API calls, well under rate limit |
| 3 | Verify users + locations match expectations | 5 min, you (eyeball) | dashboard view at /workforce (to be built) |
| 4 | `/workforce` dashboard page: labour-pct heatmap (day × site), top-spend staff, shift cost trend | 60 min, me | mirrors /touchoffice + /caterbook style |
| 5 | Cross-join view: `daily_unit_economics` — touchoffice_fixed_totals JOIN workforce_wage_comparisons by date+site, gives sales/cost/profit in one row per (date, site) | 30 min, me | this is the prize — one table for "did the pub make money today" |
| 6 | n8n schedule trigger at 02:30 calling the sync script | 10 min, me | before TouchOffice 03:00 cron |
| 7 | Webhook subscription (POST /api/v2/webhooks) for shift-edit events → near-real-time labour pct | 45 min, me | optional, defer until daily sync proven |

**Total:** 5 min you + ~2.5h me, after creds.

## What I can do *before* creds arrive (already done in this turn)

- ✓ V29 migration applied — six workforce_* tables exist
- ✓ `scripts/u29-workforce-creds.sh` — Vault stash helper, validates the token against /users/me before storing
- ✓ `scripts/u29-workforce-sync.sh` — full sync orchestrator (users, locations, shifts, wage_comparisons), idempotent UPSERTs, sync log
- The sync script's pre-check returns a clean error today (no creds) and will start working the moment the credential script runs

## Anti-scope

- Payroll runs (`/api/v2/payroll/*`) — defer; we don't yet write to
  payroll and Xero is the canonical payroll truth via P3
- Real-time webhooks — defer to U31 once daily sync is proven
- Self-onboarding staff (POST /users/onboarding) — defer; admin still
  uses the Workforce UI for hires
- LeaveBalances editing — read-only is enough for v1

## Acceptance

- [ ] `secret/workforce` populated and `/users/me` returns 200 in the creds script
- [ ] Initial 365-day sync completes; `workforce_users`, `workforce_shifts`,
      `workforce_wage_comparisons` have rows
- [ ] `daily_unit_economics` view returns a row per (date, site) for the
      last 30 days with sales and labour cost both non-null
- [ ] `/workforce` dashboard page rendering on phone
- [ ] Daily cron at 02:30 fires after Tanda's nightly batch (verify by
      `workforce_sync_log.runtime_ms` having recent entries)
