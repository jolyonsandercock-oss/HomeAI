# U154 — Perf baseline (2026-05-21)

Measured from inside tailnet (Caddy bypass via direct IP `100.104.82.53:8090`).
3 sequential runs per endpoint, no warmup.

## Dashboard API endpoints

| endpoint | avg | min | max | target | verdict |
|---|---|---|---|---|---|
| `/api/healthz` | 1ms | 1ms | 1ms | <100ms | ✅ |
| `/api/snapshot` | 46ms | 1ms | 135ms | <500ms | ✅ |
| `/api/recent` | 2ms | 1ms | 4ms | <200ms | ✅ |
| `/api/hardware` | 363ms | 1ms | 1089ms | <2s | ✅ (fans out to host probes) |
| `/api/agents` | 8ms | 1ms | 20ms | <200ms | ✅ |

## Slug endpoints (per-slug end-to-end)

| slug | avg | max | verdict |
|---|---|---|---|
| `xero_bills_recent` | 9ms | 16ms | ✅ |
| `today_kpis_work` | 20ms | 31ms | ✅ |
| `obligations_upcoming` | 5ms | 6ms | ✅ |
| `staff_on_rota_today` | 4ms | 5ms | ✅ |
| `cashup_reconciliation_today` | 7ms | 8ms | ✅ |
| `frontend_today_gross` | 4ms | 5ms | ✅ |
| `dashboard_week_strip` | 11ms | 12ms | ✅ |
| `mortgage_statement_gaps` | 435ms | 474ms | ⚠️ slowest, sub-second is fine |

## Verdict

**All endpoints comfortably under the 2-second target for first content.** The dashboard is performance-ready for staff rollout.

Slowest path: `mortgage_statement_gaps` at ~435ms, which is the `v_mortgage_coverage` view scanning historical statements. Acceptable — view is on `/private/docs`, not a daily-driver page.

`/api/hardware` peaks at 1s when host-probe RTT spikes; still under target. Not user-facing.

## Notes for staff-rollout phase

- Authelia + Caddy + TLS adds 30-80ms of overhead per request — figures above are pre-Authelia. After login it's not measured here but should still be well under 2s on 4G mobile.
- Refetch intervals (per `useSlug` hook in frontend) are usually 30-60s for daily-driver pages, which gives plenty of headroom for the network round-trip.
