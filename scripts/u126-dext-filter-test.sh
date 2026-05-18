#!/usr/bin/env bash
# Focused test — just the filter step. Snapshot at each click.
set -euo pipefail
rm -f /home_ai/data/dext-profile/Singleton*
SHOT=/home_ai/data/dext-recon
mkdir -p "$SHOT"

/home_ai/data/dext-venv/bin/python - <<'PY'
import time
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(
        '/home_ai/data/dext-profile',
        executable_path='/home_ai/data/playwright-browsers/chromium-1148/chrome-linux/chrome',
        headless=True,
        viewport={'width': 1600, 'height': 1000},
        args=['--no-sandbox', '--disable-dev-shm-usage'])
    page = ctx.new_page()

    page.goto('https://app.dext.com/delta/costs/archive', wait_until='load', timeout=120000)
    page.wait_for_selector('button:has-text("Export all")', timeout=90000)
    page.screenshot(path='/home_ai/data/dext-recon/F0-loaded.png')
    print('F0: loaded')

    # Click funnel
    funnel = page.locator('.s-button-filter-transparent').first
    funnel.click()
    page.wait_for_timeout(1500)
    page.screenshot(path='/home_ai/data/dext-recon/F1-funnel-open.png')
    print('F1: funnel clicked')

    # Find ALL buttons in panel and list their text
    pills = page.locator('aside button, .filter button, [class*="filter"] button').all()
    print(f'   found {len(pills)} buttons in filter area')
    for pi, btn in enumerate(pills[:50]):
        try:
            txt = btn.inner_text(timeout=500).strip()
            if txt: print(f'     pill[{pi}] = {txt!r}')
        except Exception: pass

    # Try clicking "Without extraction warnings" via exact match
    print('-- attempting click: button matching "Without extraction warnings"')
    candidates = [
        'button:has-text("Without extraction warnings")',
        'button:text-is("Without extraction warnings")',
        'text="Without extraction warnings"',
        '*:has-text("Without extraction warnings")',
    ]
    for sel in candidates:
        try:
            n = page.locator(sel).count()
            print(f'   {sel}: count={n}')
            if n > 0:
                page.locator(sel).first.click(timeout=3000)
                print(f'   ✓ clicked using {sel}')
                break
        except Exception as e:
            print(f'   {sel}: ERR {e}')
    page.wait_for_timeout(800)
    page.screenshot(path='/home_ai/data/dext-recon/F2-pill-clicked.png')
    print('F2: pill clicked')

    # Click Apply
    page.click('button:has-text("Apply")', timeout=4000)
    page.wait_for_timeout(3000)
    page.screenshot(path='/home_ai/data/dext-recon/F3-applied.png')
    print('F3: Apply clicked — current archive count:')
    # Page title should now show fewer items
    try:
        txt = page.locator('text=/Showing|of \\d+ items/i').first.inner_text(timeout=2000)
        print(f'   {txt}')
    except Exception as e:
        print(f'   (no count visible: {e})')

    ctx.close()
PY
echo
ls -la /home_ai/data/dext-recon/F*.png 2>&1 | head
