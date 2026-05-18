#!/usr/bin/env bash
# u126-dext-recon.sh — open Dext, click Tools dropdown, screenshot menu options.
# Quick discovery script — figures out where Export/Download lives in this Dext UI.

set -euo pipefail

VENV=/home_ai/data/dext-venv
CHROME=/home_ai/data/playwright-browsers/chromium-1148/chrome-linux/chrome
PROFILE_DIR=/home_ai/data/dext-profile
SHOT_DIR=/home_ai/data/dext-recon
mkdir -p "$SHOT_DIR"

"$VENV/bin/python" - "$CHROME" "$PROFILE_DIR" "$SHOT_DIR" <<'PY'
import sys, time
from playwright.sync_api import sync_playwright

CHROME, PROFILE, SHOT = sys.argv[1:4]

with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(
        PROFILE,
        executable_path=CHROME,
        headless=True,
        viewport={'width': 1600, 'height': 1000},
        args=['--no-sandbox', '--disable-dev-shm-usage'],
    )
    page = ctx.new_page()

    for url in ['https://app.dext.com/delta/costs/archive',
                'https://app.dext.com/delta/costs/inbox',
                'https://app.dext.com/delta/submission-history',
                'https://app.dext.com/delta/suppliers',
                'https://app.dext.com/exports']:
        try:
            print(f'-- visiting {url}')
            page.goto(url, wait_until='domcontentloaded', timeout=20000)
            page.wait_for_timeout(2500)
            slug = url.rsplit('/', 1)[-1] or 'root'
            page.screenshot(path=f'{SHOT}/page-{slug}.png', full_page=True)
            print(f'   saved page-{slug}.png  (URL is now: {page.url})')

            # If we see a Tools button, click it and screenshot the menu
            try:
                tools = page.locator('button:has-text("Tools")').first
                if tools.is_visible(timeout=1500):
                    tools.click()
                    page.wait_for_timeout(800)
                    page.screenshot(path=f'{SHOT}/tools-{slug}.png', full_page=True)
                    print(f'   saved tools-{slug}.png')
                    # Snapshot the menu text
                    menu_html = page.locator('.d-popover, .d-dropdown, [role="menu"]').first.inner_html(timeout=2000)
                    open(f'{SHOT}/tools-{slug}-menu.html', 'w').write(menu_html)
                    print(f'   menu HTML → tools-{slug}-menu.html')
            except Exception as e:
                print(f'   (no Tools menu visible: {e})')

            # Also kebab menu (ellipsis)
            try:
                for sel in ['.s-button-ellipsis', 'button[aria-label*="More" i]',
                            'button[aria-label*="Menu" i]']:
                    kbb = page.locator(sel).first
                    if kbb.is_visible(timeout=800):
                        kbb.click()
                        page.wait_for_timeout(600)
                        page.screenshot(path=f'{SHOT}/kebab-{slug}.png', full_page=True)
                        print(f'   saved kebab-{slug}.png')
                        break
            except Exception:
                pass

        except Exception as e:
            print(f'   ERR: {e}')
    ctx.close()
    print(f'\n✓ screenshots in {SHOT}/')
PY

ls -la /home_ai/data/dext-recon/
