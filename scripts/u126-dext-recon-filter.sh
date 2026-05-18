#!/usr/bin/env bash
# Recon — click the filter funnel and screenshot what Dext shows.
set -euo pipefail
VENV=/home_ai/data/dext-venv
CHROME=/home_ai/data/playwright-browsers/chromium-1148/chrome-linux/chrome
PROFILE=/home_ai/data/dext-profile
SHOT=/home_ai/data/dext-recon
mkdir -p "$SHOT"

"$VENV/bin/python" - "$CHROME" "$PROFILE" "$SHOT" <<'PY'
import sys, time
from playwright.sync_api import sync_playwright
CHROME, PROFILE, SHOT = sys.argv[1:4]
with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(
        PROFILE, executable_path=CHROME, headless=True,
        viewport={'width': 1600, 'height': 1000},
        args=['--no-sandbox', '--disable-dev-shm-usage'])
    page = ctx.new_page()
    page.goto('https://app.dext.com/delta/costs/archive', wait_until='domcontentloaded', timeout=30000)
    page.wait_for_load_state('networkidle', timeout=20000)
    page.screenshot(path=f'{SHOT}/before-funnel.png', full_page=False)
    print(f'before-funnel.png saved (URL: {page.url})')

    # Click the filter funnel icon
    clicked = False
    for sel in ['.s-button-filter-transparent',
                'button[aria-label*="filter" i]',
                'button[title*="filter" i]',
                'button.s-button-filter-transparent',
                '.js-tutorial-target-costs-inbox-filters button',
                'button:has(svg) >> nth=2']:
        try:
            page.locator(sel).first.click(timeout=2000)
            print(f'  clicked: {sel}')
            clicked = True
            break
        except Exception:
            continue
    if not clicked:
        print('  ! could not click any filter selector')
    page.wait_for_timeout(1500)
    page.screenshot(path=f'{SHOT}/after-funnel.png', full_page=False)
    print('after-funnel.png saved')
    # Save the panel HTML
    try:
        panel = page.locator('[role="dialog"], .filter-panel, .d-popover, aside').first
        open(f'{SHOT}/filter-panel.html', 'w').write(panel.inner_html(timeout=2000))
        print('filter-panel.html saved')
    except Exception as e:
        print(f'  (no panel HTML: {e})')
    ctx.close()
PY
ls -la /home_ai/data/dext-recon/
