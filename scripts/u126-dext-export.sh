#!/usr/bin/env bash
# u126-dext-export.sh — headless daily CSV export from Dext (native host).
#
# Re-uses the persistent profile from u126-dext-pair.sh. Drives the
# "Export → CSV" button programmatically.
#
# Cron: 30 6 * * *  (06:30 daily)
# Output: /home_ai/data/dext-exports/dext-YYYY-MM-DD.csv

set -euo pipefail

EXPORT_DIR=/home_ai/data/dext-exports
PROFILE_DIR=/home_ai/data/dext-profile
VENV=/home_ai/data/dext-venv
CHROME=/home_ai/data/playwright-browsers/chromium-1148/chrome-linux/chrome
mkdir -p "$EXPORT_DIR"

[ -x "$VENV/bin/python" ] || { echo "venv missing — pair first"; exit 1; }
[ -x "$CHROME" ]          || { echo "chromium missing at $CHROME"; exit 1; }
[ -d "$PROFILE_DIR" ] && [ -n "$(ls -A "$PROFILE_DIR" 2>/dev/null)" ] || {
  echo "profile empty — pair first: /home_ai/scripts/u126-dext-pair.sh"; exit 1;
}

DAYS_BACK="${DAYS_BACK:-35}"
TODAY=$(date +%Y-%m-%d)
FROM=$(date -d "$DAYS_BACK days ago" +%Y-%m-%d)
OUT="$EXPORT_DIR/dext-$TODAY.csv"

"$VENV/bin/python" - "$CHROME" "$PROFILE_DIR" "$FROM" "$TODAY" "$OUT" <<'PY'
import sys, os
from playwright.sync_api import sync_playwright

CHROME, PROFILE, FROM, TO, OUT = sys.argv[1:6]

with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(
        PROFILE,
        executable_path=CHROME,
        headless=True,
        viewport={'width': 1400, 'height': 900},
        accept_downloads=True,
        args=['--no-sandbox', '--disable-dev-shm-usage'],
    )
    page = ctx.new_page()

    print('-- navigating to Dext Costs')
    page.goto('https://app.dext.com/costs', wait_until='domcontentloaded', timeout=30000)
    page.wait_for_load_state('networkidle', timeout=20000)

    if 'login' in page.url.lower() or 'sign-in' in page.url.lower():
        print(f'ERR: bounced to {page.url} — session expired, re-pair', file=sys.stderr)
        ctx.close(); sys.exit(2)

    # Date filter (best-effort — selectors vary)
    try:
        page.click('text=/Date|Filter|Period/i', timeout=3000)
        page.wait_for_timeout(500)
        page.click('text=/Custom|Date range/i', timeout=2000)
        page.fill('input[name="from"], input[placeholder*="From" i]', FROM)
        page.fill('input[name="to"], input[placeholder*="To" i]',     TO)
        page.click('button:has-text("Apply"), button:has-text("Filter")')
        page.wait_for_timeout(1500)
    except Exception as e:
        print(f'(date filter skipped: {e})')

    print('-- triggering CSV export')
    with page.expect_download(timeout=60000) as dlinfo:
        for selector in ['button:has-text("Export")','button:has-text("Download CSV")',
                         'a:has-text("Export")','[aria-label*="Export" i]']:
            try: page.click(selector, timeout=4000); break
            except Exception: continue
        try: page.click('text=/CSV|Comma/i', timeout=3000)
        except Exception: pass
    dl = dlinfo.value
    dl.save_as(OUT)
    print(f'-- saved: {OUT}  size={os.path.getsize(OUT)} bytes')
    ctx.close()
PY

echo "✓ Exported to $OUT"
echo "  Run parser: /home_ai/scripts/u126-dext-parse.sh"
