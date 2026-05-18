#!/usr/bin/env bash
# Diagnostic — open Dext archive headless, snapshot every 3 seconds.
# Tells me exactly what the page looks like over time so I can stop guessing.
set -euo pipefail
SHOT=/home_ai/data/dext-recon
mkdir -p "$SHOT"
rm -f "$SHOT"/diag-*.png "$SHOT"/diag-*.txt

/home_ai/data/dext-venv/bin/python - <<'PY'
import time
from playwright.sync_api import sync_playwright

SHOT = '/home_ai/data/dext-recon'

with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(
        '/home_ai/data/dext-profile',
        executable_path='/home_ai/data/playwright-browsers/chromium-1148/chrome-linux/chrome',
        headless=True,
        viewport={'width': 1600, 'height': 1000},
        args=['--no-sandbox', '--disable-dev-shm-usage'],
    )
    page = ctx.new_page()
    page.set_default_navigation_timeout(120000)

    print('>> goto')
    page.goto('https://app.dext.com/delta/costs/archive', wait_until='commit', timeout=120000)

    # Snapshot every 3s for 30s
    for i in range(1, 11):
        try:
            page.screenshot(path=f'{SHOT}/diag-{i:02d}.png', full_page=False)
            title = page.title()
            url = page.url
            # What text content is visible?
            try:
                body_chars = len(page.locator('body').inner_text(timeout=2000))
            except Exception:
                body_chars = -1
            # Specific element checks
            has_export = page.locator('button:has-text("Export all")').count()
            has_login  = page.locator('input[type=email]').count()
            has_inbox  = page.locator('text=Costs inbox').count()
            print(f'  t={i*3:>3}s  title={title!r}  body={body_chars}c  url={url}  '
                  f'export={has_export} login={has_login} inbox={has_inbox}')
        except Exception as e:
            print(f'  t={i*3:>3}s  SNAPSHOT ERR: {e}')
        time.sleep(3)

    # Final state
    page.screenshot(path=f'{SHOT}/diag-final.png', full_page=True)
    open(f'{SHOT}/diag-final.html', 'w').write(page.content())
    ctx.close()
PY

echo
echo "── Diagnostic snapshots:"
ls -la /home_ai/data/dext-recon/diag-*.png 2>/dev/null
