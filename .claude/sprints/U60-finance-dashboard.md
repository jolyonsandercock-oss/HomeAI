# U60 — Finance dashboard, NL ask, inter-entity owings

**Status:** shipped 2026-05-14 (remote, autonomous after one mid-build user check-in).

## Landed

### Schema (V74, V74b)
- `v_inter_entity_owings` — net flow per entity-pair from `account_transfers`.
- `v_account_balances_now` — most recent balance per `bank_account`, with `is_liability` flag for credit cards.
- `v_finance_monthly_summary` — `(month, entity, account_type, category)` rollup.
- `v_finance_recent_unified` — last 90d of bank txns + invoices + dojo settlements in one feed.
- `v_top_vendors_window` — vendor_invoice_inbox 12-month rollup.
- `v_finance_kpis` — single-row scalar pack (cash, CC debt, MTD in/out, transfers 30d, 12-mo interest + fees).
- 11 finance slugs seeded in `query_whitelist` (V74b).

### Endpoints (build-dashboard)
- `GET  /finance`                     → page
- `GET  /api/finance/kpis`            → v_finance_kpis row
- `GET  /api/finance/slugs`           → discoverable list
- `GET  /api/finance/slug/{slug}`     → run a slug with QS params
- `POST /api/finance/ask`             → Haiku-4.5 tool-use over the 11 slugs

### UI
- `static/finance.html` — Tailwind + Alpine + Tabulator (matches existing pages).
- KPI ribbon (4 tiles).
- "Ask" box with 6 quick-suggestion buttons and free-text.
- 8 tabs: Balances, Inter-entity, Transfers, Costs/month, Spend by category, Top vendors, Credit cards, Recent events.

### Infra
- build-dashboard joined `ai-egress` network (was internal-only) so /api/finance/ask can hit api.anthropic.com.
- `VAULT_TOKEN` added to its env so it can read `secret/anthropic`.

## Verified

```
GET  /api/finance/kpis            → total_cash -£12,235 ; CC debt £22,006 ; 12mo interest £3,444
POST /api/finance/ask q="How much interest have I paid in the last year?"
  → tool=interest_paid_window(days=365), narrative names all 7 accounts
POST /api/finance/ask q="Which entity owes whom what?"
  → tool=owings_summary, narrative spells out 4 entity-pair flows
```

## Gotchas worth keeping
- `_NAMED_PARAM_RE` must use `(?<!:)` lookbehind to skip PG `::` type-cast operators.
- asyncpg's prepared-statement type inference balks at `:days::text` when binding an int. Slug SQL uses `:days * INTERVAL '1 day'` (numeric arithmetic) instead of `(:days || ' days')::interval` (text concat).
- REALM_ENFORCE=1 means raw `http://100.104.82.53:8090/finance` returns 401. Access goes via `https://jolybox.tailc27dff.ts.net/finance` (Authelia gate sets `Remote-Groups`) or `http://100.104.82.53:8090/finance` with `X-Realm: owner` header (test/scripts only).

## Open follow-ons
1. Realm gating on slugs themselves: today all 11 are realm=owner, so a work-realm caller wouldn't see them. Some (e.g. `top_vendors_window`) make sense to expose to work realm too.
2. Charts. Tabs are tables only; add a sparkline strip beside KPIs and a line chart on Costs/month.
3. Drill-through. Clicking a row in Transfers should open the underlying bank_transactions pair side-by-side.
4. Save the question→slug pairs into `query_rejections`/a new `nl_ask_log` so we can audit + retrain.
