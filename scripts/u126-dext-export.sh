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
    page.goto('https://app.dext.com/delta/costs/archive',
              wait_until='commit', timeout=60000)
    page.wait_for_load_state('networkidle', timeout=30000)

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
        page.wait_for_timeout(1200)
        page.click('button:has-text("Without extraction warnings"), '
                   'span:has-text("Without extraction warnings")',
                   timeout=4000)
        page.wait_for_timeout(400)
        page.click('button:has-text("Apply")', timeout=4000)
        page.wait_for_timeout(2500)
        page.wait_for_load_state('networkidle', timeout=15000)
    except Exception as e:
        print(f'(filter apply failed: {e})')

    dismiss_modals()

    print('-- triggering CSV export')
    try:
        # Step 1: open the "Export all items" modal
        page.click('button:has-text("Export all")', timeout=5000)
        page.wait_for_timeout(800)

        # Step 2: modal has tabs CSV/PDF/ZIP — CSV is default. Confirm it.
        try:
            page.click('button:has-text("CSV"), [role="tab"]:has-text("CSV")', timeout=2000)
        except Exception: pass
        page.wait_for_timeout(300)

        # Step 3: click the modal's confirm Export button (the small dark one)
        with page.expect_download(timeout=120000) as dlinfo:
            # Use role+name to be precise — there are two "Export" buttons
            # ("Export all" outside the modal, "Export" inside)
            for sel in [
                '.d-modal-overlay button:has-text("Export")',
                '[role="dialog"] button:has-text("Export")',
                'div:has(> :text("Export all items")) button:has-text("Export")',
                'button[type="submit"]:has-text("Export")',
            ]:
                try:
                    page.click(sel, timeout=3000); break
                except Exception:
                    continue
            else:
                raise RuntimeError('Modal Export confirm button not found')
        dl = dlinfo.value
        dl.save_as(OUT)
        print(f'-- saved: {OUT}  size={os.path.getsize(OUT)} bytes')
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
