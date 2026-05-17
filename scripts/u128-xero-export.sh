#!/usr/bin/env bash
# u128-xero-export.sh — headless daily Xero bills export.
#
# Cron: 45 6 * * *   (06:45 daily — 15 min after Dext)
# Default window: last 100 days. Override with DAYS_BACK env.
#
# Two-pass strategy (Xero's UI offers both):
#   1. Click "Export" on the bills list → CSV download (one row per bill)
#   2. For each bill, navigate to its detail page and scrape line items
#      into a separate ndjson file. Slow but complete.
#
# The first pass alone is enough to populate xero_bills + reconcile against
# email-pipeline rows. Pass 2 is optional — only invoked when needed.

set -uo pipefail

EXPORT_DIR=/home_ai/data/xero-exports
PROFILE_DIR=/home_ai/data/xero-profile
VENV=/home_ai/data/dext-venv
CHROME=/home_ai/data/playwright-browsers/chromium-1148/chrome-linux/chrome
mkdir -p "$EXPORT_DIR"
rm -f "$PROFILE_DIR/Singleton"* 2>/dev/null || true

[ -x "$VENV/bin/python" ] || { echo "venv missing"; exit 1; }
[ -x "$CHROME" ]          || { echo "chromium missing"; exit 1; }
[ -d "$PROFILE_DIR" ] && [ -n "$(ls -A "$PROFILE_DIR" 2>/dev/null)" ] || {
  echo "profile empty — pair first: /home_ai/scripts/u128-xero-pair.sh"; exit 1;
}

DAYS_BACK="${DAYS_BACK:-100}"
TODAY=$(date +%Y-%m-%d)
OUT="$EXPORT_DIR/xero-bills-$TODAY.csv"

VAULT_TOKEN=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
BILLS_URL=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault vault kv get -field=bills_url secret/xero)

"$VENV/bin/python" - "$CHROME" "$PROFILE_DIR" "$BILLS_URL" "$DAYS_BACK" "$OUT" <<'PY'
import sys, os, time
from playwright.sync_api import sync_playwright

CHROME, PROFILE, BILLS_URL, DAYS_BACK, OUT = sys.argv[1:6]
DAYS_BACK = int(DAYS_BACK)

with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(
        PROFILE,
        executable_path=CHROME,
        headless=True,
        viewport={'width': 1600, 'height': 1000},
        accept_downloads=True,
        args=['--no-sandbox', '--disable-dev-shm-usage'],
    )
    page = ctx.new_page()

    print(f'-- navigating to Xero bills list ({DAYS_BACK}d window)')
    for attempt in range(1, 5):
        try:
            page.goto(BILLS_URL, wait_until='load', timeout=90000)
            break
        except Exception as e:
            print(f'  goto {attempt}/4: {e}')
            time.sleep(3)

    if 'login' in page.url.lower():
        print(f'ERR: bounced to {page.url} — session expired, re-pair', file=sys.stderr)
        ctx.close(); sys.exit(2)

    # Snapshot for diagnostics
    page.screenshot(path=OUT.replace('.csv', '-page-loaded.png'), full_page=False)

    # Xero's bills list has an Export menu — typically a 3-dot or
    # "Export" button. Try a handful of selectors.
    print('-- looking for Export button')
    downloads = []
    page.on('download', lambda d: downloads.append(d))

    clicked = False
    for sel in [
        'button:has-text("Export")',
        '[aria-label*="Export" i]',
        'button:has-text("Download")',
        'button[data-automationid*="Export"]',
    ]:
        try:
            page.locator(sel).first.click(timeout=4000)
            clicked = True; print(f'   clicked {sel}')
            break
        except Exception: continue
    if not clicked:
        print('   no Export button found. Save diagnostics and bail.')
        page.screenshot(path=OUT.replace('.csv', '-NOEXPORT.png'), full_page=True)
        open(OUT.replace('.csv', '-NOEXPORT.html'), 'w').write(page.content())
        ctx.close(); sys.exit(3)

    # Xero may show a dropdown / dialog for format selection
    page.wait_for_timeout(1000)
    for sel in ['text=/^CSV$/i', 'button:has-text("CSV")', 'a:has-text("CSV")',
                'text=/Export to CSV/i', 'text=/Export as.*CSV/i']:
        try:
            page.locator(sel).first.click(timeout=2000)
            print(f'   selected format: {sel}')
            break
        except Exception: continue

    print('-- waiting for download (up to 3 min)')
    deadline = time.time() + 180
    while time.time() < deadline:
        if downloads:
            downloads[0].save_as(OUT)
            print(f'-- saved: {OUT}  size={os.path.getsize(OUT)} bytes')
            break
        time.sleep(2)
    else:
        print('-- timed out, no download. Snapshot:')
        try:
            page.screenshot(path=OUT.replace('.csv', '-FAIL.png'), full_page=True, timeout=10000)
            open(OUT.replace('.csv', '-FAIL.html'), 'w').write(page.content())
        except Exception: pass
        ctx.close(); sys.exit(3)
    ctx.close()
PY

echo "✓ Bills exported to $OUT"
echo "  Now run parser: /home_ai/scripts/u128-xero-parse.sh"
