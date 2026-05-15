# Cash count + daily reconciliation flow — end-to-end review

Generated 2026-05-15. Read-only.

## User journey (intended)

```
1. Jo opens /m on phone (Authelia → realm=work)
2. Cashing-up card visible — pickers for site/date/session
3. Jo enters z_reading, card_total, cash_counted, float_returned
4. Submit → POST /api/till-recon
5. Server computes variance + status, inserts till_reconciliation row
6. If variance > £5 → status='flagged' → exception raised in /recon
7. If exception severity='critical' → critical-listener fires → Telegram
8. Nightly cron runs L1/L2/L3 reconciliation against Dojo + bank
```

## Step-by-step health

| Step | Component | State | Notes |
|---|---|---|---|
| 1 | `/m` page + Authelia realm gate | ✅ working | U57 R3+R4 shipped |
| 2 | `/m` cashing-up card | ✅ working | U71 T1 shipped (per-site form) |
| 3 | Form fields | ⚠ partial | `expected_cash` is optional — when Jo doesn't enter it, variance is NULL and no flag fires. See "expected_cash gap" below. |
| 4 | `POST /api/till-recon` | ✅ working | Idempotent on (site, recon_date, session). |
| 5 | Variance computation | ⚠ partial | Only fires when both `cash_counted` AND `expected_cash` populated. |
| 6 | Exception raised to `/recon` | ⚠ unclear | No automatic emission of `mart.exceptions` from till_reconciliation flag. /recon shows till variance separately. |
| 7 | Critical Telegram | ✅ working | U71 T2 trigger fires on `mart.exceptions WHERE severity='critical'`. |
| 8 | Nightly L1/L2/L3 + morning digest | ✅ working | U67/U68/U69 cron scripts all in place. |

## The expected_cash gap

The till submit endpoint allows `expected_cash` to be NULL. When it is:
- `variance = NULL`
- `status = 'ok'` (default)
- No flag, no Telegram

This means the reconciliation only works if Jo manually computes expected cash
on his phone before submitting. There's no automatic computation from
TouchOffice + Caterbook + bank-feed.

**Recommendation**: server should auto-compute `expected_cash` from:
- `touchoffice_department_sales` for that site + date + session = cash department component
- minus `caterbook_daily_snapshots` revenue (cards/online accommodation already on Stripe/Dojo)
- minus `float_returned`

Then variance vs `cash_counted` is mechanical.

```sql
expected_cash = (
    SELECT sum(value)
      FROM touchoffice_department_sales
     WHERE site = $site
       AND report_date = $recon_date
       AND department IN ('CASH SALES','TILL SALES')  -- or whatever Jo's cash departments are called
) - $float_returned
```

## Missing-data hunter check

`v_ghost_shifts` already detects "site sold but no shifts" — but no equivalent for
"site sold but no cash count". The U72 `till_recon_missing` hunter only fires per
calendar day, ignoring session (day/night).

**Recommendation**: hunter should fire per (site, date, session) tuple, since
day and night sessions cash up separately.

## Where critical exceptions actually surface

Currently no trigger inserts a `mart.exceptions` row when `till_reconciliation`
gets `status='flagged'`. `/recon` page reads the variance directly from
till_reconciliation. So:

- ✅ /recon shows it
- ✅ /recon traffic-light works
- 🔴 critical-listener never fires (because no row in mart.exceptions)
- 🔴 Telegram silent

**Recommendation**: add an INSERT trigger on `till_reconciliation` that
fires an `mart.exceptions` row when `variance > £10` (or threshold from
`ops_thresholds.variance_gbp`).

## Recommendations rolled up for U93

| # | Fix | Effort |
|---|---|---|
| T1 | Auto-compute `expected_cash` from TouchOffice + Caterbook | ~30 min |
| T2 | Per-session (day/night) till_recon_missing hunter | ~15 min |
| T3 | Trigger on till_reconciliation → mart.exceptions for variance > £10 | ~20 min |
| T4 | Add cafe site to the till form (currently optional but workflow-untested) | ~15 min |

## Daily pipeline still healthy

- u67-recon-l1: cron 30 4 * * * — daily totals
- u68-recon-l2: nightly orchestrator
- u68-recon-l3: settlement matching
- u69-morning-digest: 06:00 daily Telegram
- u72-missing-data-hunters: cron 5 6 * * * — fires the till_recon_missing
- u75-pipeline-smoke: cron 30 6 * * * — Brother scan smoke

All present + on schedule. Logs show recent runs.
