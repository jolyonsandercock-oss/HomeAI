# U159 — Phase 7 kickoff: revenue-side close-the-loop

**Prereqs**: U151+U155 stability locked. Dojo + TouchOffice + Caterbook ingest all healthy.

**Realm**: `work`.

**Remote vs in-person**: 100% remote.

**Why this sprint exists**: Phase 6 told Jo what he *spent*. Phase 7 tells him what he *earned*. Revenue data is in the system across multiple tables (touchoffice_department_sales, dojo_transactions, caterbook_room_nights, restaurant_reservations) but never aggregated into a single picture. Daily revenue, source split, week trend — the operational mirror of the expense rollup Jo already has.

## Tracks

### T1 — frontend_revenue_today slug (~45 min)

**Build**: V182 migration — new slug `frontend_revenue_today`:

```sql
WITH today AS (SELECT CURRENT_DATE AS d)
SELECT 'rooms' AS source, COALESCE(SUM(rate_per_night), 0)::numeric(12,2) AS gross_gbp
  FROM caterbook_room_nights WHERE night_date = (SELECT d FROM today)
UNION ALL
SELECT 'food_drink', COALESCE(SUM(value), 0)::numeric(12,2)
  FROM touchoffice_department_sales WHERE report_date = (SELECT d FROM today)
UNION ALL
SELECT 'card_payments', COALESCE(SUM(transaction_amount), 0)::numeric(12,2)
  FROM dojo_transactions WHERE transaction_date = (SELECT d FROM today)
    AND transaction_outcome = 'Authorised' AND transaction_type = 'Sale';
```

Plus `frontend_revenue_7d` for week trend.

**Acceptance**: both slugs return rows; tested via `/api/finance/slug/`.

### T2 — Revenue tile on /work/today (~60 min)

**Build**: React component reading `frontend_revenue_today` + `frontend_revenue_7d`. Top-card layout:
- TODAY gross (£X,XXX) big number
- vs same day last week (% indicator green/amber/red)
- 3-row breakdown: rooms / food+drink / card-payments
- Mini sparkline of last 7 days

Place above the existing cost/expense tile so revenue → expense reads naturally.

**Acceptance**: tile renders with live data; refresh interval 5 min.

### T3 — Daily revenue narrative email (~90 min)

**Build**:
- `scripts/u159-revenue-email.sh` — assembles HTML email matching u109 v4 format (per `feedback_email_format_canonical`).
- Sonnet narrative: "Yesterday gross was £X, vs £Y same day last week (Z%). Rooms £R (N stays), food+drink £F (mix: lunch X / dinner Y), cards £C."
- Cron: `0 9 * * *` (after Dojo daily sync at 5:30).
- Sent to Jo via google-fetch /send/jo.

**Acceptance**: email arrives 09:00 each morning; format passes Jo's eye.

### T4 — Drill-down route (~60 min)

**Build**: `/work/revenue` page on homeai-frontend.
- Date picker (today, yesterday, last 7d).
- Per-source breakdown: rooms (by room type), food+drink (by department), card-payments (by site).
- VAT-relevant flag per line.
- Link from /work/today revenue tile.

**Acceptance**: click revenue tile → lands on drill-down; date picker works.

### T5 — VAT line classification (~45 min)

**Build**: new column `vat_relevant boolean` on touchoffice_department_sales + caterbook_room_nights via V183. Bootstrap rules:
- Rooms = vat_relevant true (standard rate)
- Alcohol food departments = vat_relevant true
- Soft drink food = vat_relevant true
- Tips/gratuities (per dojo) = vat_relevant false

Surface as `vat_relevant_revenue_quarter` slug for Jo's VAT prep.

**Acceptance**: VAT total queryable for current quarter.

## Done criteria

- /work/today shows today's revenue prominently above expenses.
- Daily 09:00 email lands in Jo's inbox.
- VAT total queryable for current quarter.
- All slugs healthy on next selftest run.

## Risk

Low. All source data is in DB. This is aggregation + surfacing, no new ingest.

Related: [[project-u128-xero]] (cost side), [[feedback-email-format-canonical]], [[caterbook-revenue-derivation]].
