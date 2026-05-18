#!/usr/bin/env bash
# u128-xero-export.sh — daily Xero bills export.
#
# Cron: 45 6 * * *   (06:45 daily — 15 min after Dext)
# Default window: last 100 days. Override with DAYS_BACK env.
#
# Modes:
#   XERO_HEADED=1   force headed Chromium on $DISPLAY (matches pair fingerprint;
#                   bypasses the Akamai bounce-to-login that hits headless runs)
#   default         headless (currently fails — Akamai re-fingerprints)
#
# Two-pass strategy: pass 1 (CSV bills list) is enough for xero_bills +
# reconciliation. Pass 2 (per-bill line items) is optional and not yet wired.

set -euo pipefail

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

DAYS_BACK="${DAYS_BACK:-30}"
TODAY=$(date +%Y-%m-%d)
OUT="$EXPORT_DIR/xero-bills-$TODAY.csv"
HEADED="${XERO_HEADED:-0}"

if [ "$HEADED" = "1" ]; then
  [ -n "${DISPLAY:-}" ] || { echo "XERO_HEADED=1 but DISPLAY unset"; exit 1; }
  xset -display "$DISPLAY" q >/dev/null 2>&1 || { echo "DISPLAY=$DISPLAY unreachable"; exit 1; }
  echo "── headed mode on DISPLAY=$DISPLAY"
fi

VAULT_TOKEN=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
BILLS_URL=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault vault kv get -field=bills_url secret/xero)

export HEADED
set +e
"$VENV/bin/python" - "$CHROME" "$PROFILE_DIR" "$BILLS_URL" "$DAYS_BACK" "$OUT" <<'PY'
import sys, os, time
from datetime import date, timedelta
from playwright.sync_api import sync_playwright

CHROME, PROFILE, BILLS_URL, DAYS_BACK, OUT = sys.argv[1:6]
DAYS_BACK = int(DAYS_BACK)
HEADED = os.environ.get('HEADED', '0') == '1'

with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(
        PROFILE,
        executable_path=CHROME,
        headless=not HEADED,
        viewport={'width': 1600, 'height': 1000},
        accept_downloads=True,
        args=['--no-sandbox', '--disable-dev-shm-usage'],
    )
    page = ctx.new_page()

    # Build a URL that includes startDate/endDate query params — Xero
    # honors these internally even though it rewrites them out of the
    # visible URL after load.
    today = date.today()
    from_date = today - timedelta(days=DAYS_BACK)
    sep = '&' if '?' in BILLS_URL else '?'
    url = f'{BILLS_URL}{sep}startDate={from_date.isoformat()}&endDate={today.isoformat()}'
    print(f'-- navigating to bills list with date filter ({from_date} → {today})')
    for attempt in range(1, 5):
        try:
            page.goto(url, wait_until='load', timeout=90000)
            break
        except Exception as e:
            print(f'  goto {attempt}/4: {e}')
            time.sleep(3)

    if 'login' in page.url.lower():
        print(f'ERR: bounced to {page.url} — session expired, re-pair', file=sys.stderr)
        ctx.close(); sys.exit(2)

    # Snapshot for diagnostics
    page.screenshot(path=OUT.replace('.csv', '-page-loaded.png'), full_page=False)

    # Wait for the bills page chrome to render
    try:
        page.wait_for_selector('button.bills-spa-ListPageOverflowMenu, button[aria-label="Overflow menu"]',
                               timeout=25000)
    except Exception:
        print('   bills page never finished loading.')
        page.screenshot(path=OUT.replace('.csv', '-NOEXPORT.png'), full_page=True)
        open(OUT.replace('.csv', '-NOEXPORT.html'), 'w').write(page.content())
        ctx.close(); sys.exit(3)

    # Xero bills list: Export is hidden inside the page-level Overflow
    # menu (button.bills-spa-ListPageOverflowMenu, aria-label="Overflow menu").
    # Open it, then click the Export option in the popup listbox.
    print('-- opening Overflow menu')
    downloads = []
    def attach_download(p):
        p.on('download', lambda d: downloads.append(d))
    attach_download(page)
    ctx.on('page', attach_download)

    # Let the bills list render fully — overflow menu only appears after rows load
    try:
        page.wait_for_selector('button.bills-spa-ListPageOverflowMenu, button[aria-label="Overflow menu"]',
                               timeout=20000)
    except Exception:
        print('   overflow menu never appeared. Save diagnostics and bail.')
        page.screenshot(path=OUT.replace('.csv', '-NOEXPORT.png'), full_page=True)
        open(OUT.replace('.csv', '-NOEXPORT.html'), 'w').write(page.content())
        ctx.close(); sys.exit(3)

    clicked = False
    for sel in [
        'button.bills-spa-ListPageOverflowMenu',
        'button[aria-label="Overflow menu"]',
    ]:
        try:
            page.locator(sel).first.click(timeout=4000)
            clicked = True; print(f'   opened overflow ({sel})')
            break
        except Exception: continue
    if not clicked:
        print('   failed to open Overflow menu.')
        page.screenshot(path=OUT.replace('.csv', '-NOEXPORT.png'), full_page=True)
        open(OUT.replace('.csv', '-NOEXPORT.html'), 'w').write(page.content())
        ctx.close(); sys.exit(3)

    page.wait_for_timeout(800)

    # Click "Export bills" in the popup. Xero uses role=option for menu items.
    print('-- clicking Export bills in overflow popup')
    exported = False
    for sel in [
        '[role="option"]:has-text("Export bills")',
        '[role="menuitem"]:has-text("Export bills")',
        'li:has-text("Export bills")',
        'a:has-text("Export bills")',
        'button:has-text("Export bills")',
        '[role="option"]:has-text("Export")',
        'li:has-text("Export")',
        'text=/^Export$/',
    ]:
        try:
            page.locator(sel).first.click(timeout=3000)
            exported = True; print(f'   clicked Export option ({sel})')
            break
        except Exception: continue
    if not exported:
        print('   Export option not found in overflow popup.')
        page.screenshot(path=OUT.replace('.csv', '-NOEXPORT.png'), full_page=True)
        open(OUT.replace('.csv', '-NOEXPORT.html'), 'w').write(page.content())
        ctx.close(); sys.exit(3)

    # Confirmation modal: "You're exporting N items… Do you want to export?"
    # Refuses early if N > 500.
    page.wait_for_timeout(1500)
    try:
        body_text = page.locator('.xui-modal--body').first.inner_text(timeout=4000)
        print(f'   modal: {body_text.strip()[:200].replace(chr(10), " | ")}')
        if 'more than 500' in body_text.lower() or 'cannot export' in body_text.lower():
            print(f'   Xero refused export — too many items. Lower DAYS_BACK (current={DAYS_BACK}d).')
            page.screenshot(path=OUT.replace('.csv', '-TOOBIG.png'), full_page=True)
            ctx.close(); sys.exit(4)
    except Exception as e:
        print(f'   (no modal body found: {e})')

    # Click the modal's "Export" CTA to confirm, wrapped in expect_download
    # so we deterministically catch the response.
    print('-- confirming export in modal')
    confirm_locator = None
    for sel in [
        '.xui-modal--footer button:has-text("Export")',
        '.xui-modal--footer button.xui-button-main',
        '.xui-modal--footer button[name="Export"]',
        'button:has-text("Export"):not(.bills-spa-ListPageOverflowMenu)',
    ]:
        loc = page.locator(sel).first
        try:
            loc.wait_for(state='visible', timeout=2000)
            confirm_locator = (loc, sel); break
        except Exception: continue
    if not confirm_locator:
        print('   could not find Export confirm button.')
        page.screenshot(path=OUT.replace('.csv', '-NOCONFIRM.png'), full_page=True)
        open(OUT.replace('.csv', '-NOCONFIRM.html'), 'w').write(page.content())
        ctx.close(); sys.exit(3)

    loc, sel = confirm_locator
    print(f'   confirming via {sel}')
    download = None
    try:
        with page.expect_download(timeout=120000) as dl_info:
            loc.click(timeout=4000)
        download = dl_info.value
        print(f'   download started: suggested_filename={download.suggested_filename}')
    except Exception as e:
        print(f'   expect_download did not fire ({e}); checking event-fed queue…')
        # Fall back to the event-fed queue (some Xero variants emit download
        # on a popup page, captured via ctx.on('page')).
        deadline = time.time() + 90
        while time.time() < deadline and not downloads:
            time.sleep(1)
        if downloads:
            download = downloads[0]
            print(f'   captured via context event: {download.suggested_filename}')

    if not download:
        print('   no download event ever fired.')
        page.screenshot(path=OUT.replace('.csv', '-NODOWNLOAD.png'), full_page=True)
        open(OUT.replace('.csv', '-NODOWNLOAD.html'), 'w').write(page.content())
        ctx.close(); sys.exit(3)

    download.save_as(OUT)
    size = os.path.getsize(OUT)
    print(f'-- saved: {OUT}  size={size} bytes')
    ctx.close()
    if size < 100:
        print(f'   ✗ file suspiciously small ({size} bytes)', file=sys.stderr)
        sys.exit(5)
    print(f'✓ Bills CSV ready: {OUT}')
    sys.exit(0)
PY
rc=$?
set -e
if [ $rc -ne 0 ]; then
  echo "✗ Xero export failed (rc=$rc). See artefacts in $EXPORT_DIR." >&2
  exit $rc
fi
echo "✓ Bills exported to $OUT"
echo "  Now run parser: /home_ai/scripts/u128-xero-parse.sh"
