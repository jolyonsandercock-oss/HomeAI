# U32 — finish dashboard tables UX + cross-pipeline economics + P7

**Goal:** by end-of-sprint, every dashboard page is sortable / filterable /
click-through, *and* there's a single "did the business make money today"
view joining sales (TouchOffice), accommodation revenue (Caterbook), and
labour cost (Workforce). Plus P7 Cashing Up flips on now that the sheet
creds are in.

## Why these three together

- **U31 leftovers** are the lowest-friction win — the infra is built
  (Tabulator + viewer endpoints proven on /invoices). Migrating the other
  four pages is mechanical.
- **`daily_unit_economics`** is the headline business metric the whole
  build is pointing at. We finally have all three feeders alive: P5
  TouchOffice, P6 Caterbook, U30 Workforce. Joining them is one view +
  one page.
- **P7 Cashing Up** unblocks the "variance > £5 → Telegram alert" line
  in the SPEC. The sheet creds are sitting in Vault unused.

## Chunks

| # | Chunk | Cost | Owner |
|---|---|---|---|
| 1 | `/touchoffice` migration to Tabulator: 4 tables, recent_scrapes rows link → `/viewer/snapshot/<file>.html` | 30 min | me |
| 2 | `/caterbook` migration: 4 tables, arrival/stayover/departure rows link → `/viewer/email/info/<source_email_id>` + PDF inline | 40 min | me |
| 3 | `/workforce` migration: 4 tables, top_staff link → `my.workforce.com/users/<id>`, recent_sync error rows expand-on-click | 30 min | me |
| 4 | `/` Mission Control migration: debt + tasks + agents + recent events → Tabulator. Picks up the queued broader Dashboard Refactor pieces (paginated registries, status badges) from `project_dashboard_refactor.md` memory | 90 min | me |
| 5 | V31 migration: `daily_unit_economics` materialised view (date, site, net_sales, gross_sales, covers, accom_in_house_revenue, labour_hours, labour_cost_est, labour_pct) | 30 min | me |
| 6 | `/economics` dashboard page rendering V31 view + weekly trend chart | 60 min | me |
| 7 | P7 Cashing Up sheet parser: reads `2026CashUp!Cash Up Sheets` weekly-blocks, writes `till_reconciliation`, joins TouchOffice for variance flagging | 90 min | me |
| 8 | P7 cron at 23:30 daily (after the till is closed for the night) | 10 min | me |
| 9 | Workforce `/departments` sync — gives the dashboard human-readable names instead of 593833/etc | 30 min | me |
| 10 | Invoice PDF auto-extraction — fetch each `vendor_invoice_inbox` row's PDF, regex amount/due_date/invoice_no, write back | 60 min | me |
| 11 | Phone-first `/m` landing page — today's totals + due invoices + scrape health, auto-refresh | 45 min | me |

**Total:** ~9h me, 0 user. (Or split across two sessions — chunks 1-6 in
day 1, 7-11 in day 2.)

## Anti-scope

- P3 Xero (parked — awaiting Xero support reply on the OAuth error)
- Dashboard refactor's *full* tiered hierarchy (phase-gate progress bar
  + dragging) — chunks here cover the table parts; that hierarchy is
  U33 if still wanted after these land
- Webhooks for any of Workforce / Gmail (still poll-based, sufficient)
- Server-side pagination — `workforce_shifts` is 1,400 rows, well under
  the threshold where it'd matter

## Open questions / known-unknowns

- **Labour cost estimation:** `workforce_shifts` doesn't carry a cost
  field. Need to derive from `hours_worked × workforce_users.base_pay_rate`
  — but `base_pay_rate` is only populated on some user rows in the
  current sync. Either populate from a separate API call (e.g.
  `/api/v2/user_pay_fields`) in U33, or accept "labour_cost_est = NULL"
  for users without a stored rate in V31 v1
- **Variance band:** SPEC §App-C says `OK` if `ABS(I) ≤ 5 AND ABS(I/F*100) ≤ 0.5`.
  Real till data may have more noise — first dry-run might find variance
  thresholds need widening. Code the threshold in a constants table so
  it's tunable
- **TouchOffice 3-year backfill** is still running in the background (started
  2026-05-11). Don't restart the playwright container during the sprint
  unless we want to interrupt that job. Last checkpoint when this plan was
  written: still in progress

## Acceptance

- [ ] Every dashboard page has sortable headers + per-column filter
- [ ] `/economics?days=30` returns one row per (date, site) with sales
      and labour cost both populated for most days
- [ ] A test cashing-up entry with cash counted £100 off Z-reading
      triggers a Telegram alert at the next P7 run
- [ ] `/m` renders correctly at 375px viewport with no horizontal scroll
- [ ] All Workforce shifts show their department by name (not numeric id)
