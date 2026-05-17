#!/usr/bin/env bash
# u126-dext-export.sh — headless daily CSV export from Dext.
#
# Re-uses the persistent profile cookies from u126-dext-pair.sh. Drives the
# UI's "Export → CSV" button programmatically; this is the same action a
# logged-in human would do, hence ToS-safe.
#
# Cron: 30 6 * * *   (06:30 daily — well after Dext finishes overnight OCR)
#
# Output: /home_ai/data/dext-exports/dext-YYYY-MM-DD.csv

set -euo pipefail

EXPORT_DIR=/home_ai/data/dext-exports
PROFILE_DIR=/home_ai/data/dext-profile
mkdir -p "$EXPORT_DIR"

# Window: default to last 35 days (covers a full month + grace).
DAYS_BACK="${DAYS_BACK:-35}"
TODAY=$(date +%Y-%m-%d)
FROM=$(date -d "$DAYS_BACK days ago" +%Y-%m-%d)
OUT="$EXPORT_DIR/dext-$TODAY.csv"

docker run --rm \
  --network home_ai_ai-egress \
  -v "$PROFILE_DIR":/profile \
  -v "$EXPORT_DIR":/exports \
  -e FROM_DATE="$FROM" \
  -e TO_DATE="$TODAY" \
  -e OUT_FILE="/exports/dext-$TODAY.csv" \
  --shm-size 2g \
  home_ai-playwright-service:latest \
  python3 -c "
import os, time, sys, glob
from playwright.sync_api import sync_playwright

FROM = os.environ['FROM_DATE']
TO   = os.environ['TO_DATE']
OUT  = os.environ['OUT_FILE']

with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(
        '/profile',
        headless=True,
        viewport={'width': 1400, 'height': 900},
        accept_downloads=True,
    )
    page = ctx.new_page()

    print('-- navigating to Dext Costs view')
    page.goto('https://app.dext.com/costs', wait_until='domcontentloaded', timeout=30000)
    page.wait_for_load_state('networkidle', timeout=20000)

    # If we're bounced to login, the session has expired — bail loudly
    if 'login' in page.url.lower() or 'sign-in' in page.url.lower():
        print(f'ERR: bounced to {page.url} — session expired, re-pair with u126-dext-pair.sh', file=sys.stderr)
        ctx.close()
        sys.exit(2)

    # Set the date range filter — Dext UI varies; try common selectors
    try:
        # Click date filter
        page.click('text=/Date|Filter|Period/i', timeout=3000)
        page.wait_for_timeout(500)
        # Custom date range
        page.click('text=/Custom|Date range/i', timeout=2000)
        page.fill('input[name=\"from\"], input[placeholder*=\"From\" i]', FROM)
        page.fill('input[name=\"to\"], input[placeholder*=\"To\" i]', TO)
        page.click('button:has-text(\"Apply\"), button:has-text(\"Filter\")')
        page.wait_for_timeout(1500)
    except Exception as e:
        print(f'(date-filter step failed, taking default view: {e})')

    print('-- triggering CSV export')
    with page.expect_download(timeout=60000) as dlinfo:
        # Click 'Export' / 'Download'
        for selector in ['button:has-text(\"Export\")', 'button:has-text(\"Download CSV\")',
                         'a:has-text(\"Export\")', '[aria-label*=\"Export\" i]']:
            try:
                page.click(selector, timeout=5000)
                break
            except Exception:
                continue
        # In a dropdown? click CSV option if it appeared
        try:
            page.click('text=/CSV|Comma/i', timeout=3000)
        except Exception:
            pass
    dl = dlinfo.value
    dl.save_as(OUT)
    print(f'-- saved: {OUT}  size={os.path.getsize(OUT)} bytes')
    ctx.close()
"

echo "✓ Exported to $OUT"
echo "  Size: $(stat -c%s "$OUT" 2>/dev/null || echo '?') bytes"
echo
echo "── Next: parse into vendor_invoice_lines:"
echo "    /home_ai/scripts/u126-dext-parse.sh $OUT"
