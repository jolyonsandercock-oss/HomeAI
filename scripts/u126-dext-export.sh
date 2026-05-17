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

# Clear any orphan Singleton locks from a previous run that crashed
rm -f "$PROFILE_DIR/Singleton"* 2>/dev/null || true

[ -x "$VENV/bin/python" ] || { echo "venv missing — pair first"; exit 1; }
[ -x "$CHROME" ]          || { echo "chromium missing at $CHROME"; exit 1; }
[ -d "$PROFILE_DIR" ] && [ -n "$(ls -A "$PROFILE_DIR" 2>/dev/null)" ] || {
  echo "profile empty — pair first: /home_ai/scripts/u126-dext-pair.sh"; exit 1;
}

DAYS_BACK="${DAYS_BACK:-30}"
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

    print('-- navigating to Dext Archive (full archive — we filter via UI)')
    # Dext doesn't support date filtering via URL params on this view.
    # The funnel has no date filter. Strategy: apply "Without extraction
    # warnings" to skip incomplete rows (which block the export), then
    # export everything. We narrow to a date window inside our DB after parse.
    # Use 'load' (window onload) — fully-loaded resources. Dext SPA still
    # bootstraps after this, so wait for a specific button to appear.
    page.goto('https://app.dext.com/delta/costs/archive',
              wait_until='load', timeout=90000)
    # Hard wait for the SPA to finish hydrating
    print('  (waiting for Dext SPA to hydrate…)')
    try:
        page.wait_for_selector('button:has-text("Export all")', timeout=90000, state='visible')
        print('  Export all button visible — page is ready')
    except Exception as e:
        print(f'  ! Export all never appeared after 90s: {e}')
        # Save state for debugging
        page.screenshot(path=OUT.replace('.csv', '-NOBUTTON.png'), full_page=True)
        open(OUT.replace('.csv', '-NOBUTTON.html'), 'w').write(page.content())
        raise

    if 'login' in page.url.lower() or 'sign-in' in page.url.lower():
        print(f'ERR: bounced to {page.url} — session expired, re-pair', file=sys.stderr)
        ctx.close(); sys.exit(2)

    def dismiss_modals():
        """Close any blocking overlays — Dext shows banners/welcomes/tutorials."""
        for sel in [
            'button[aria-label*="close" i]',
            'button[aria-label*="dismiss" i]',
            '.d-modal-overlay button',
            '.modal__close', '.modal-close',
            'button:has-text("Got it")', 'button:has-text("Close")',
            'button:has-text("Skip")',   'button:has-text("Dismiss")',
            'button:has-text("Maybe later")', 'button:has-text("No thanks")',
        ]:
            try:
                while page.locator(sel).first.is_visible(timeout=500):
                    page.locator(sel).first.click(timeout=2000)
                    page.wait_for_timeout(300)
            except Exception:
                pass
        # Plus an Escape press for good measure
        try: page.keyboard.press('Escape')
        except Exception: pass
        page.wait_for_timeout(500)

    dismiss_modals()

    # Open the filter funnel, click "Without extraction warnings", Apply.
    # This is the only way to exclude the rows that have null totals (which
    # block "Export all" with "Please set total amount for each of the
    # items in the export").
    print('-- applying "Without extraction warnings" filter')
    try:
        page.locator('.s-button-filter-transparent').first.click(timeout=5000)
        page.wait_for_timeout(1500)
        # Pills are spans/divs, not <button> — exact text match works
        page.locator('text="Without extraction warnings"').first.click(timeout=4000)
        page.wait_for_timeout(500)
        page.click('button:has-text("Apply")', timeout=4000)
        page.wait_for_timeout(4000)
        # Verify the filter took effect — count should drop
        try:
            count_txt = page.locator('text=/of \\d+ items/i').first.inner_text(timeout=2000)
            print(f'   filtered to: {count_txt}')
        except Exception: pass
    except Exception as e:
        print(f'(filter apply failed: {e})')

    dismiss_modals()

    print('-- opening Export all modal')
    page.click('button:has-text("Export all")', timeout=5000)
    page.wait_for_timeout(1000)
    page.screenshot(path=OUT.replace('.csv', '-pre-export.png'))

    # Verify the error is GONE (filter should have removed problem rows)
    try:
        err = page.locator('text="Please set total amount"').first
        if err.is_visible(timeout=1000):
            print('  ✗ "Please set total amount" still visible — filter did not stop the block')
        else:
            print('  ✓ no extraction-warning error on modal')
    except Exception: pass

    print('-- clicking modal Export confirm (no expect_download — will poll instead)')
    clicked = False
    for sel in ['.d-modal-overlay button:has-text("Export"):not(:has-text("Export all"))',
                '[role="dialog"] button:has-text("Export")',
                'button[type="submit"]:has-text("Export")']:
        try:
            page.click(sel, timeout=3000); clicked = True; print(f'   clicked: {sel}'); break
        except Exception:
            continue
    if not clicked:
        # Fallback: click "Export" exact-text inside the modal
        try:
            page.locator('button').filter(has_text='Export').nth(-1).click(timeout=3000)
            clicked = True; print('   clicked via nth(-1)')
        except Exception as e:
            print(f'   ! no Export-confirm button found: {e}')

    # Just wait passively for the download event. Don't screenshot during
    # the wait — Dext blocks JS rendering when preparing a large export and
    # page.screenshot() times out. The download listener is registered, we
    # just need patience.
    import time as _t
    downloads = []
    page.on('download', lambda d: downloads.append(d))
    print('-- waiting for download event (up to 5 minutes, 8839 items takes time)')
    deadline = _t.time() + 300
    while _t.time() < deadline:
        if downloads:
            dl = downloads[0]
            dl.save_as(OUT)
            print(f'-- saved: {OUT}  size={os.path.getsize(OUT)} bytes')
            break
        _t.sleep(2)
    else:
        print('-- timed out, no download arrived in 5 min')
        try:
            page.screenshot(path=OUT.replace('.csv', '-FAIL.png'), full_page=True, timeout=10000)
            open(OUT.replace('.csv', '-FAIL.html'), 'w').write(page.content())
        except Exception: pass
        ctx.close(); sys.exit(3)
    except Exception as e:
        # Save diagnostic snapshot on download timeout / unknown failure
        shot = OUT.replace('.csv', '-FAIL.png')
        html = OUT.replace('.csv', '-FAIL.html')
        try:
            page.screenshot(path=shot, full_page=True)
            open(html, 'w').write(page.content())
            print(f'-- failed: {e}\n   snapshot: {shot}\n   dom: {html}')
        except Exception: pass
        ctx.close(); sys.exit(3)
    ctx.close()
PY

echo "✓ Exported to $OUT"
echo "  Run parser: /home_ai/scripts/u126-dext-parse.sh"
