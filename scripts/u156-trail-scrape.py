#!/usr/bin/env python3
"""
U156 — Trail report scraper (STUB pending interactive pair).

Status: BLOCKED pending Jo running u156-trail-pair.sh on the console
(DISPLAY=:0). Once that completes, this script picks up the persisted
profile at /home_ai/data/trail-profile/ and scrapes recent reports.

The actual scrape logic is intentionally not fully fleshed out because
Access aCloud's Trail web app structure is unknown until we can reach
the post-login pages. After Jo pairs successfully, the next step is
to walk the Reports section, identify the table HTML, write selectors.

Run inside homeai-playwright container.

Usage:
  docker exec homeai-playwright python3 /tmp/u156-trail-scrape.py
"""
import asyncio
import os
import sys

from playwright.async_api import async_playwright


PROFILE = "/home_ai/data/trail-profile"
WEB_URL = os.environ.get("TRAIL_WEB_URL", "https://web.trailapp.com")
CHROME  = "/home_ai/data/playwright-browsers/chromium-1148/chrome-linux/chrome"


async def main():
    if not os.path.exists(f"{PROFILE}/Default/Cookies"):
        print("✗ No Trail profile cookies — run u156-trail-pair.sh first", file=sys.stderr)
        sys.exit(2)

    async with async_playwright() as p:
        ctx = await p.chromium.launch_persistent_context(
            PROFILE, executable_path=CHROME,
            headless=True,
            args=['--no-sandbox', '--disable-dev-shm-usage'],
            viewport={'width': 1600, 'height': 1000},
        )
        page = ctx.pages[0] if ctx.pages else await ctx.new_page()

        # Try to reach the dashboard
        await page.goto(WEB_URL, wait_until='domcontentloaded', timeout=30000)
        await page.wait_for_timeout(3000)

        # Check we're past login
        if 'identity.accessacloud.com' in page.url:
            print(f'✗ Session expired or never paired — bounced to {page.url}', file=sys.stderr)
            await ctx.close()
            sys.exit(3)

        print(f'✓ Reached Trail at {page.url}')
        print('  TODO: walk Reports / Tasks / Compliance pages once we know the URLs')
        print('       Inspect /tmp/u156-trail-landing.html (saved next) to find selectors')

        html = await page.content()
        open('/tmp/u156-trail-landing.html', 'w').write(html)
        print(f'  saved {len(html)} bytes to /tmp/u156-trail-landing.html')
        await ctx.close()


if __name__ == "__main__":
    asyncio.run(main())
