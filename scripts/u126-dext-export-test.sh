#!/usr/bin/env bash
# Focused test — click "Export all" → modal Export → screenshot 3s after.
# Tells me whether Dext sends a download OR emails the file.

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
        accept_downloads=True,
        args=['--no-sandbox', '--disable-dev-shm-usage'])
    page = ctx.new_page()

    # Listen for downloads in background so we can tell if one happened
    downloads = []
    page.on('download', lambda d: downloads.append(d))

    print('-- goto archive')
    page.goto('https://app.dext.com/delta/costs/archive',
              wait_until='load', timeout=120000)
    page.wait_for_selector('button:has-text("Export all")', timeout=90000)
    print('-- archive loaded, clicking Export all')
    page.click('button:has-text("Export all")')
    page.wait_for_timeout(2000)
    page.screenshot(path='/home_ai/data/dext-recon/step1-modal-open.png')
    print('-- modal opened — saved step1-modal-open.png')

    # Click the modal's Export (confirm) button
    print('-- clicking modal Export')
    for sel in ['.d-modal-overlay button:has-text("Export")',
                '[role="dialog"] button:has-text("Export")']:
        try: page.click(sel, timeout=3000); print(f'   clicked {sel}'); break
        except Exception: pass

    # Wait + screenshot every 2s for 10s to see what happens
    for i in range(1, 6):
        time.sleep(2)
        page.screenshot(path=f'/home_ai/data/dext-recon/step2-after-{i}.png')
        # Check for toast / banner indicating async export
        try:
            toasts = page.locator('.toaster, .toast, [role="status"], .notification').all_inner_texts()
            print(f'   t+{i*2}s  downloads={len(downloads)}  toasts={toasts[:3]}')
        except Exception as e:
            print(f'   t+{i*2}s  downloads={len(downloads)}  toast-err={e}')

    open('/home_ai/data/dext-recon/step2-final.html', 'w').write(page.content())
    print('-- done. downloads:', len(downloads), [d.suggested_filename for d in downloads])
    ctx.close()
PY

echo
echo "── Screenshots:"
ls -la /home_ai/data/dext-recon/step*.png /home_ai/data/dext-recon/step*.html 2>&1 | head
