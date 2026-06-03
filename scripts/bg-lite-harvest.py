#!/usr/bin/env python3
"""
bg-lite-harvest.py — harvest British Gas Lite per-property account numbers
and reconcile them into account_property_map / property_utilities.

WHY
---
BG Lite "your bill is ready to view" emails are portal-only: no PDF, no
account number. We seeded account_property_map (2026-06-03) keyed on the
per-property *billing-reference string* (the property name BG puts in each
email subject). This script logs into the BG Lite portal and back-fills the
real numeric account numbers + MPRN so the mapping is fully keyed.

CREDS (Vault)
-------------
  secret/britishgaslite : { "username": "...", "password": "..." }
Store with:  /home_ai/scripts/store-bg-lite-creds.sh

RUN
---
  docker exec -e VAULT_TOKEN homeai-playwright \
      python3 /home_ai/scripts/bg-lite-harvest.py            # live
  ...add --dry-run to scrape + print without writing to the DB.

FIRST RUN IS EXPLORATORY: BG Lite's post-login DOM is unverified. The script
saves the accounts-page HTML to /tmp/bg-lite-accounts.html so selectors can
be confirmed, then attempts a best-effort extraction. Verify the mapping it
prints before trusting the DB write (use --dry-run first).
"""
import argparse
import asyncio
import json
import os
import re
import sys

import asyncpg
import httpx
from playwright.async_api import async_playwright

VAULT_ADDR = os.environ.get("VAULT_ADDR", "http://vault:8200")
VAULT_TOKEN = os.environ.get("VAULT_TOKEN", "")
PG_DSN = os.environ.get("PG_DSN", "postgresql://postgres:99RedBalloons!@homeai-postgres:5432/homeai")
PROFILE = "/home_ai/data/bg-lite-profile"
CHROME = "/home_ai/data/playwright-browsers/chromium-1148/chrome-linux/chrome"
# TODO verify on first run — BG Lite business online-account login.
LOGIN_URL = os.environ.get("BG_LITE_LOGIN_URL", "https://www.britishgaslite.co.uk/my-account/")

# Maps BG property/site label -> the billing-ref string already seeded in
# account_property_map (so we update the right row).
SITE_HINTS = {
    "malthouse": "Ye Olde Malthouse Fore Street",
    "langholme": "Unit 1, Langholme Atlantic Road",
    "flat":      "The Flat, 1 Castle Road",
    "garage":    "The Garage, 1 Castle Road",
}


async def vault_creds() -> dict:
    if not VAULT_TOKEN:
        sys.exit("✗ VAULT_TOKEN not in env. Run inside container with -e VAULT_TOKEN.")
    async with httpx.AsyncClient() as c:
        r = await c.get(f"{VAULT_ADDR}/v1/secret/data/britishgaslite",
                        headers={"X-Vault-Token": VAULT_TOKEN}, timeout=15)
    if r.status_code != 200:
        sys.exit(f"✗ Vault read secret/britishgaslite failed: HTTP {r.status_code}. "
                 f"Store creds first via store-bg-lite-creds.sh")
    return r.json()["data"]["data"]


def match_billing_ref(address: str) -> str | None:
    a = (address or "").lower()
    for hint, ref in SITE_HINTS.items():
        if hint in a:
            return ref
    return None


async def scrape() -> list[dict]:
    creds = await vault_creds()
    async with async_playwright() as p:
        ctx = await p.chromium.launch_persistent_context(
            PROFILE, executable_path=CHROME, headless=True,
            args=["--no-sandbox", "--disable-dev-shm-usage"],
            viewport={"width": 1600, "height": 1000},
        )
        page = ctx.pages[0] if ctx.pages else await ctx.new_page()
        await page.goto(LOGIN_URL, wait_until="domcontentloaded", timeout=40000)
        await page.wait_for_timeout(2500)

        # Best-effort login — selectors unverified, wrapped so we still dump HTML.
        try:
            for sel in ('input[type="email"]', 'input[name*="user" i]', '#username'):
                if await page.locator(sel).count():
                    await page.fill(sel, creds["username"]); break
            for sel in ('input[type="password"]', '#password'):
                if await page.locator(sel).count():
                    await page.fill(sel, creds["password"]); break
            for sel in ('button[type="submit"]', 'button:has-text("Sign in")', 'button:has-text("Log in")'):
                if await page.locator(sel).count():
                    await page.click(sel); break
            await page.wait_for_timeout(5000)
        except Exception as e:
            print(f"⚠ login step incomplete ({e}); continuing to dump page for selector work")

        if "captcha" in (await page.content()).lower() or "verify" in page.url.lower():
            print("⚠ Hit a verification/captcha wall — needs interactive pairing on console "
                  "(DISPLAY=:0), like the Trail flow. Stopping.", file=sys.stderr)

        html = await page.content()
        open("/tmp/bg-lite-accounts.html", "w").write(html)
        print(f"  saved {len(html)} bytes -> /tmp/bg-lite-accounts.html (inspect to confirm selectors)")

        # Best-effort extraction: BG account numbers are ~10 digits; pair each
        # with the nearest property address text. UNVERIFIED — confirm vs HTML.
        text = re.sub(r"<[^>]+>", " ", html)
        accounts = re.findall(r"\b(\d{9,12})\b", text)
        results = []
        for blk in re.split(r"(?=Unit 1|The Flat|The Garage|Ye Olde Malthouse|Malthouse)", text):
            ref = match_billing_ref(blk)
            m = re.search(r"\b(\d{9,12})\b", blk)
            mprn = re.search(r"MPRN[:\s]*([0-9]{6,12})", blk, re.I)
            if ref and m:
                results.append({"billing_ref": ref, "account_number": m.group(1),
                                "mprn": mprn.group(1) if mprn else None})
        await ctx.close()
        return results


async def write_db(rows: list[dict]):
    conn = await asyncpg.connect(PG_DSN)
    try:
        for r in rows:
            await conn.execute(
                """update account_property_map
                      set account_display = account_display || ' (BG a/c '||$2||')',
                          notes = regexp_replace(notes,'numeric BG account no\\. pending portal harvest\\.?',
                                                 'BG account '||$2||' harvested '||now()::date)
                    where vendor_domain='britishgaslite.co.uk' and account_number=$1""",
                r["billing_ref"], r["account_number"])
            await conn.execute(
                """update property_utilities
                      set account_number=$2, mpan_or_mprn=$3, updated_at=now()
                    where utility_kind='gas' and notes ilike '%'||$1||'%'""",
                r["billing_ref"], r["account_number"], r.get("mprn"))
        print(f"✓ DB updated for {len(rows)} accounts")
    finally:
        await conn.close()


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    rows = await scrape()
    print(f"\nHarvested {len(rows)} property→account rows:")
    for r in rows:
        print(f"  {r['billing_ref']:34} -> BG a/c {r['account_number']}  MPRN={r.get('mprn')}")
    if not rows:
        print("  (none — selectors need confirming against /tmp/bg-lite-accounts.html)")
        return
    if args.dry_run:
        print("\n--dry-run: not writing to DB.")
    else:
        await write_db(rows)


if __name__ == "__main__":
    asyncio.run(main())
