import asyncio, os
from playwright.async_api import async_playwright

URL = "https://business.britishgas.co.uk/business/your-account/login?int=login-aboutlite"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")
USER, PASS = os.environ["BG_USER"], os.environ["BG_PASS"]
OUT = "/tmp/bg_bills"
os.makedirs(OUT, exist_ok=True)


async def login(page):
    await page.goto(URL, wait_until="networkidle", timeout=40000); await page.wait_for_timeout(2500)
    for sel in ["#onetrust-accept-btn-handler", "#onetrust-reject-all-handler"]:
        b = await page.query_selector(sel)
        if b:
            try: await b.click(); await page.wait_for_timeout(1200); break
            except Exception: pass
    e = await page.query_selector("input[type=email], input[name*=email i], input[id*=email i]")
    await e.click(); await e.type(USER, delay=55); await page.wait_for_timeout(500)
    pw = await page.query_selector("input[type=password], input[name*=pass i]")
    await pw.click(); await pw.type(PASS, delay=55); await page.wait_for_timeout(600)
    await (await page.query_selector("button[type=submit], button:has-text('Log in'), button:has-text('Sign in')")).click()
    try: await page.wait_for_load_state("networkidle", timeout=30000)
    except Exception: pass
    await page.wait_for_timeout(4000)


async def download_account(page, idx):
    """idx = which View button (account)."""
    views = await page.query_selector_all("button:has-text('View'), a:has-text('View')")
    if idx >= len(views): return 0
    await views[idx].click()
    try: await page.wait_for_load_state("networkidle", timeout=20000)
    except Exception: pass
    await page.wait_for_timeout(3000)
    acct = page.url.rstrip("/").split("/")[-1]
    # go to bills
    bills_link = await page.query_selector("a:has-text('View your bills'), a[href*='view-bill']")
    if bills_link:
        await bills_link.click()
        try: await page.wait_for_load_state("networkidle", timeout=20000)
        except Exception: pass
        await page.wait_for_timeout(3500)
    dl_buttons = await page.query_selector_all("button:has-text('Download'), a:has-text('Download'), button:has-text('pdf'), a:has-text('pdf')")
    print(f"  account {acct}: {len(dl_buttons)} download buttons")
    n = 0
    for i, b in enumerate(dl_buttons):
        try:
            async with page.expect_download(timeout=20000) as di:
                await b.click()
            d = await di.value
            await d.save_as(f"{OUT}/bg_{acct}_{i:02d}_{d.suggested_filename}")
            n += 1
            await page.wait_for_timeout(1500)  # human pace
        except Exception as ex:
            print(f"    dl {i} failed: {str(ex)[:60]}")
    return n


async def run():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True, args=["--no-sandbox"])
        ctx = await browser.new_context(user_agent=UA, locale="en-GB",
                                        viewport={"width": 1280, "height": 900}, accept_downloads=True)
        page = await ctx.new_page()
        await login(page)
        if "login" in page.url.lower():
            print("OUTCOME: LOGIN_FAILED"); await browser.close(); return
        print("OUTCOME: LOGGED_IN")
        total = 0
        for idx in range(2):  # 2 accounts
            try:
                total += await download_account(page, idx)
            except Exception as ex:
                print(f"  account idx {idx} error: {str(ex)[:60]}")
            await page.goto("https://business.britishgas.co.uk/business/app/organisations", wait_until="networkidle", timeout=30000)
            await page.wait_for_timeout(3000)
        print("TOTAL_DOWNLOADED:", total)
        await browser.close()


asyncio.run(run())
