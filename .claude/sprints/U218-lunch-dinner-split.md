# U218 — Lunch/dinner split from TouchOffice bill timestamps

**Scoping done by U217 — implementation pending.**

## What we found

TouchOffice Web exposes per-bill (per-transaction) data via a DataTables endpoint with **timestamp resolution to the minute**. Confirmed working against the live malthouse instance during U217 probe.

### Endpoint

```
GET https://www.touchoffice.net/apps/jsonbillreportsdetails
    ?sEcho=1
    &iColumns=7
    &iDisplayStart=0
    &iDisplayLength=500            # bump to avoid pagination
    &mDataProp_0..6=0..6           # boilerplate
    &iSortCol_0=0&sSortDir_0=desc  # date desc
    &sSearch=
    # Session also carries: site selector + date range from the parent /apps/viewbillreports
```

### Response shape (DataTables format)

```json
{
  "sEcho": 1,
  "iTotalRecords": 29,
  "iTotalDisplayRecords": 29,
  "aaData": [
    ["21/05/2026 - 20:23:00", "55540", "Malthouse", "", "wi", "12", "66.50", "1"],
    ...
  ]
}
```

Columns: `[ts, bill_id, site, table, clerk_initials, check_no, total_gbp, ?]`

Per-bill timestamp + total is sufficient for **service-level split** (was this bill paid at lunch or at dinner?). Per-PLU lunch/dinner split is NOT possible — TouchOffice doesn't expose line-items with timestamps in any pre-canned report.

### Daypart cutoffs (proposed — confirm with Jo)

- **lunch**:  12:00 ≤ ts < 15:00
- **dinner**: 17:00 ≤ ts < 22:30
- **other**: everything else (breakfast trickle, late drinks, in-between coffee)

Yesterday's malthouse data confirms 20:23:00 entries → dinner. Sanity-check by site (cafe operates different hours).

## Implementation (U218 itself)

1. **Migration V199**:
   ```sql
   CREATE TABLE touchoffice_bills (
     id              BIGSERIAL PRIMARY KEY,
     site            text NOT NULL,
     bill_id         text NOT NULL,
     bill_ts         timestamptz NOT NULL,
     report_date     date NOT NULL,           -- ts::date in Europe/London
     table_no        text,
     clerk           text,
     check_no        text,
     total_gbp       numeric(10,2),
     daypart         text GENERATED ALWAYS AS (
       CASE
         WHEN bill_ts::time BETWEEN '12:00' AND '14:59:59' THEN 'lunch'
         WHEN bill_ts::time BETWEEN '17:00' AND '22:29:59' THEN 'dinner'
         ELSE 'other'
       END
     ) STORED,
     raw_row         jsonb,
     ingested_at     timestamptz DEFAULT NOW(),
     realm           text DEFAULT 'work',
     UNIQUE (site, bill_id, report_date)
   );
   CREATE INDEX idx_touchoffice_bills_date_site ON touchoffice_bills(report_date DESC, site);
   CREATE INDEX idx_touchoffice_bills_daypart ON touchoffice_bills(report_date, daypart);
   ```

2. **Add to existing TouchOffice scraper** (`services/playwright/scrapers/touchoffice.py`):
   - New widget: `bill_reports` — drive `/apps/viewbillreports` flow:
     - Select site, set date range to target date,
     - Submit form,
     - Intercept the `/apps/jsonbillreportsdetails` XHR (it's the same authenticated session),
     - For pagination: increment `iDisplayStart` by `iDisplayLength=500` until exhausted.
   - Wire into the existing `/ingest/touchoffice` endpoint so u27 daily cron picks it up automatically.

3. **Slugs**:
   - `bill_revenue_by_daypart_today` (site, daypart, total_gbp, bill_count)
   - `bill_revenue_by_daypart_7d` (rolling 7d daypart averages)
   - `bill_count_by_hour_today` (for U219 future heatmap)

4. **Frontend**:
   - `/restaurant`: replace the "Lunch/dinner split pending" note with actual ranked items split by daypart (best we can do without PLU-level times is total revenue + bill count per daypart).
   - `/`: optional — small "today: 5 lunch / 18 dinner" KPI on revenue tile.

## Estimated effort

- Scraper integration: 90 min (DataTables pagination + JSON parse is straightforward)
- Migration + slug authoring + test: 30 min
- Frontend wiring: 30 min
- Backfill last 30d via existing backfill pattern: ~30 min (one site × 30 days × ~3s/page = ~90s; both sites = ~3min)

**Total: ~3 hours.**

## Why this wasn't done in U217

User asked to *scope* lunch/dinner split, not implement. Implementation requires:
- New table (migration) → needs care around partitioning if it grows fast (each pub day = ~30 bills; cafe ~50; ~30k bills/year — fine without partitioning for now)
- Decision on daypart cutoffs (above is my proposal; Jo should confirm)
- A clean rebuild of the homeai-playwright scraper module that doesn't accidentally regress the existing 3 widgets

## Followups identified during probe

- TouchOffice has a "Reports NEW" engine at `/reports_engine/report_view` with ~80+ canned reports including "Dept By Date", "PLU Sales Comparison 52Week", "Customer Spend By Group With VAT". This is a richer data source than the home-page widgets — worth a separate sprint to enumerate.
- `/apps/hourly_breakdown_config` is an admin page (just sets the hourly-bucket interval — 10/15/30/60 min). Not a data source itself.
