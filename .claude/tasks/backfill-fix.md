# TouchOffice 5-Year Backfill — Failed at Day 1202/1825

## State
- Backfill process crashed at Sept 13, 2024 (day 1202/1825)
- All requests for dates before Sept 2024 return HTTP502 with: `Page.click: Timeout 30000ms exceeded. waiting for locator("button[name=submit-filter]")`
- Data only goes back to May 2025 (13 months), not the requested 5 years
- Scraper code: `/home_ai/services/playwright/scrapers/touchoffice.py` line 232
- Backfill script: `/home_ai/scripts/u27-touchoffice-backfill.sh`
- Playwright container is healthy and responding to health checks

## Task
1. Diagnose why `button[name="submit-filter"]` times out for dates before Sept 2024 but works for recent dates
2. Fix the scraper to handle the different UI state for historical dates OR detect the failure gracefully and skip
3. Resume the backfill from where it stopped (Sept 2024) and continue to 2021
4. Alternative: if TouchOffice doesn't have data before a certain cutoff, document that and update the backfill to stop there

## Evidence
The scraper works perfectly for recent dates (May 2025 — present). The timeout is specifically on the submit button after entering a historical date. This suggests either:
- TouchOffice doesn't have data that far back and the page shows an error state instead of the filter button
- The UI changed between 2024 and 2025
- The page loads differently for date ranges with no data

## Approach
Test scraping a few sample dates to find the cutoff:
- 2025-01-01 (should work)
- 2024-09-14 (fails)
- Find the exact boundary date where it breaks
