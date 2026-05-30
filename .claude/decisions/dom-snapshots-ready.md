# Dojo + Trail DOM snapshots ready

## Source: Hermes (from laptop, via /browser connect CDP session)
## Timestamp: 2026-05-30 15:15 UTC

Both DOM snapshot files are waiting at:
  /home/hermes-transport/claude-replies/review_20260530T151336Z_dojo-dom.md
  /home/hermes-transport/claude-replies/review_20260530T151336Z_trail-dom.md

Jo signed in interactively to both live dashboards via a headed Chromium CDP session on laptop. Hermes pierced the Shadow DOM of both sites (Dojo uses Web Components, Trail uses a split frozen-column grid) and captured the scaffolding.

### Dojo
- URL: https://account.dojo.tech/transactions
- Shadow DOM tree: DJP-SCROLLABLE-WITH-DETAILS → djp-scrollable-wrapper → djp-scrollable → djp-results-list
- Results grid uses class `results-list-groups` with `results-list-item` per transaction
- Header: `.results-list-header` with `dj-flex[data-test="transaction-header"]`
- Row: `djp-transaction-item` with cols for time + amount + card scheme
- Pagination: "Load new transactions" button (class `transactionsPolling_fullWithButton__1wlgf8e0`)
- Date picker: text inputs with data-testid `transactions-filters-date-datepicker-from-input` / `...-to-input`

### Trail
- URL: https://web.trailapp.com/reports#/scores
- Split frozen-column grid — left `.showtime-scores-table__locations`, right `.showtime-scores-table__entries`
- Header: `.showtime-scores-table__row--header` with date cells
- Location row: `.showtime-scores-table__row--location` with `div.showtime-scores-table__location` (name) + `<a>` links per-date
- Each score `<a>` has href format `/trail/<location_id>/<date-ymd>` and class `showtime-score-item`
- Date range picker: `button[data-test="filterSummary.label"]`
- No pagination — horizontally scrollable timeline grid, date-filtered via calendar

Go ahead and write the scrape() extractors, rebuild the playwright image, test headless, and wire daily cron. ~1 hour each per the original plan.
