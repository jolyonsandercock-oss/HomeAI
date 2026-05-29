"""Trail food-hygiene reports scraper (U230 — closes U156).

Trail uses Access Group SSO (OAuth2/OIDC via identity.accessacloud.com)
per memory feedback-trail-oidc-not-api. NOT a REST API — the previous
u134-trail-poll.py was a dead end.

Credentials live in Vault under secret/trail:
  username, password   (Access Group identity)

2FA flow: Access Group offers an email code option. We click email,
poll jolyon.sandercock@gmail.com via google-fetch for the just-arrived
code, and submit it. Same pattern as the Dojo scraper.

OIDC flow:
  1. GET https://app.trailapp.com → 302 to identity.accessacloud.com
  2. POST username + password to the identity form
  3. (Optional) 2FA email-code step
  4. Follow OIDC redirect chain back to Trail with bearer token in URL
  5. Trail sets its own session cookie; from there it's HTML scraping

Cookies persist to /home_ai/data/playwright-state/trail-storage.json.

Schema target: trail_reports (trail_report_id is the unique key).
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import time
import urllib.parse
import urllib.request
from datetime import date, timedelta
from pathlib import Path
from typing import Any

from playwright.async_api import Page, async_playwright  # type: ignore

from . import _debug

log = logging.getLogger(__name__)

BASE_URL  = os.environ.get("TRAIL_BASE_URL",  "https://app.trailapp.com")
LOGIN_URL = os.environ.get("TRAIL_LOGIN_URL", "https://identity.accessacloud.com")
STATE_PATH = Path(os.environ.get(
    "TRAIL_STORAGE_STATE", "/home_ai/data/playwright-state/trail-storage.json"))

GOOGLE_FETCH_URL = os.environ.get(
    "GOOGLE_FETCH_URL", "http://google-fetch:8011")
GMAIL_ACCOUNT = os.environ.get("TRAIL_2FA_GMAIL_ACCOUNT", "jo")

CODE_RE = re.compile(r"\b(\d{4,8})\b")

# Senders that send Trail / Access Group identity emails.
# Broadened with OR so we don't miss it if the from-address surprises us.
TRAIL_FROM_QUERY = "from:(trailapp OR accessacloud OR access-group OR trail.app)"


# ─── Gmail polling for the 2FA code ──────────────────────────────────

def _fetch_trail_code(after_ts: float, timeout_s: int = 180,
                      poll_every_s: int = 8) -> str | None:
    """Poll Gmail (via google-fetch) for a new Trail / Access Group 2FA
    email arriving after `after_ts` (epoch seconds). Returns the digit
    code or None on timeout.
    """
    deadline = time.time() + timeout_s
    seen: set[str] = set()
    after_ms = int(after_ts * 1000)

    list_q = urllib.parse.urlencode({
        "account": GMAIL_ACCOUNT,
        "q":       f"{TRAIL_FROM_QUERY} newer_than:10m",
        "max_results": 5,
    })
    list_url = f"{GOOGLE_FETCH_URL}/messages?{list_q}"

    while time.time() < deadline:
        try:
            with urllib.request.urlopen(list_url, timeout=8) as r:
                msgs = json.loads(r.read()).get("messages", [])
        except Exception as e:
            log.warning("trail 2fa: list_messages failed: %s", e)
            msgs = []

        msgs.sort(key=lambda m: int(m.get("internal_date") or 0), reverse=True)

        for m in msgs:
            mid = m.get("id")
            if not mid or mid in seen:
                continue
            seen.add(mid)
            idate = int(m.get("internal_date") or 0)
            if idate < after_ms:
                continue

            # 1. Snippet first.
            for match in CODE_RE.findall(m.get("snippet", "") or ""):
                if 4 <= len(match) <= 8:
                    log.info("trail 2fa: code from snippet (msg %s)", mid)
                    return match

            # 2. Full body fallback.
            try:
                full_url = f"{GOOGLE_FETCH_URL}/message/{GMAIL_ACCOUNT}/{mid}"
                with urllib.request.urlopen(full_url, timeout=8) as r:
                    body_json = json.loads(r.read())
                text = _flatten_body(body_json.get("payload", {}))
                for match in CODE_RE.findall(text):
                    if 4 <= len(match) <= 8:
                        log.info("trail 2fa: code from full body (msg %s)", mid)
                        return match
            except Exception as e:
                log.warning("trail 2fa: full body fetch failed for %s: %s", mid, e)

        time.sleep(poll_every_s)

    return None


def _flatten_body(payload: dict[str, Any]) -> str:
    import base64
    out: list[str] = []

    def walk(part: dict[str, Any]) -> None:
        mime = part.get("mimeType", "")
        body = part.get("body", {})
        data = body.get("data")
        if data and mime.startswith("text/"):
            try:
                raw = base64.urlsafe_b64decode(data + "==").decode(
                    "utf-8", errors="ignore")
                out.append(raw)
            except Exception:
                pass
        for sub in part.get("parts", []):
            walk(sub)

    walk(payload)
    return "\n".join(out)


# ─── Playwright login flow ──────────────────────────────────────────

async def _try_click_any(page: Page, candidates: list[str], *, timeout_ms: int = 4000) -> bool:
    for sel in candidates:
        try:
            loc = page.locator(sel).first
            await loc.wait_for(state="visible", timeout=timeout_ms)
            await loc.click()
            log.info("trail: clicked %s", sel)
            return True
        except Exception:
            continue
    return False


async def _try_fill_any(page: Page, candidates: list[str], value: str,
                        *, timeout_ms: int = 4000) -> bool:
    for sel in candidates:
        try:
            await page.fill(sel, value, timeout=timeout_ms)
            log.info("trail: filled %s", sel)
            return True
        except Exception:
            continue
    return False


async def _oidc_login(page: Page, username: str, password: str) -> None:
    """OIDC + email-2FA flow for Trail / Access Group identity."""
    await page.goto(BASE_URL + "/", wait_until="domcontentloaded")

    # Cookie-valid? We're either still on trailapp.com or we got bounced.
    if "trailapp.com" in page.url and not any(
        x in page.url.lower() for x in ("login", "auth", "signin")
    ):
        log.info("trail: existing session, no login needed (url=%s)", page.url)
        return

    # Access Group IdP — may take a beat to land here after the bounce.
    try:
        await page.wait_for_url(lambda url: "accessacloud.com" in url, timeout=15_000)
    except Exception:
        log.warning("trail: didn't see accessacloud.com redirect; url=%s", page.url)

    log.info("trail: starting OIDC login (url=%s)", page.url)

    # ── Username ──────────────────────────────────────────────────
    user_selectors = [
        'input[type="email"]', 'input[name="username"]', 'input[name="email"]',
        'input#username', 'input#email', 'input[name="UserName"]',
    ]
    if not await _try_fill_any(page, user_selectors, username):
        await _debug.dump_state(page, "trail", "username_fill_miss",
                                tried=user_selectors)
        raise RuntimeError("trail: no username field matched — see debug dump")

    # Some IdPs split username + password across two screens (Microsoft-style).
    # Click "Next"/"Continue" first; if a password field appears immediately
    # on the same page, the click is a no-op.
    await _try_click_any(page, [
        'button:has-text("Next")', 'button:has-text("Continue")',
        'button[type="submit"]',
    ], timeout_ms=3000)

    # ── Password ──────────────────────────────────────────────────
    pass_selectors = [
        'input[type="password"]', 'input[name="password"]', 'input#password',
        'input[name="Password"]',
    ]
    if not await _try_fill_any(page, pass_selectors, password, timeout_ms=8000):
        await _debug.dump_state(page, "trail", "password_fill_miss",
                                tried=pass_selectors)
        raise RuntimeError("trail: no password field matched — see debug dump")

    submitted = await _try_click_any(page, [
        'button[type="submit"]',
        'button:has-text("Sign in")',
        'button:has-text("Log in")',
        'button:has-text("Continue")',
    ])
    if not submitted:
        await page.keyboard.press("Enter")

    # ── 2FA method chooser (email) ────────────────────────────────
    await page.wait_for_load_state("domcontentloaded", timeout=15_000)
    await asyncio.sleep(1.0)

    picked_email = await _try_click_any(page, [
        'button:has-text("Email")',
        'button:has-text("email")',
        'a:has-text("Email")',
        'a:has-text("email")',
        'label:has-text("Email")',
        'input[type="radio"][value="email" i]',
        'input[type="radio"][value*="email" i]',
        '[data-method="email"]',
        '[aria-label*="email" i]',
    ], timeout_ms=6000)

    if picked_email:
        log.info("trail: chose email 2FA")
        await _try_click_any(page, [
            'button:has-text("Send")',
            'button:has-text("Send code")',
            'button:has-text("Continue")',
            'button[type="submit"]',
        ], timeout_ms=3000)
    else:
        log.info("trail: no 2FA chooser visible — dumping for review; "
                 "may indicate no 2FA on this account or unfamiliar chooser DOM")
        await _debug.dump_state(page, "trail", "no_2fa_chooser_found")

    # ── Look for a code input. If none, assume no 2FA. ────────────
    code_present = False
    for sel in [
        'input[name="code"]', 'input[name="otp"]', 'input[name="verificationCode"]',
        'input[autocomplete="one-time-code"]',
        'input[type="text"][maxlength="6"]',
        'input[type="tel"][maxlength="6"]',
        'input[maxlength="1"]',
    ]:
        try:
            await page.locator(sel).first.wait_for(state="visible", timeout=3000)
            code_present = True
            break
        except Exception:
            continue

    if code_present:
        code_request_ts = time.time()
        log.info("trail: polling jolyon.sandercock@gmail.com for 2FA code (up to 3 min)")
        code = await asyncio.to_thread(_fetch_trail_code, code_request_ts)
        if not code:
            await _debug.dump_state(page, "trail", "2fa_email_timeout",
                                    after_ts=code_request_ts)
            raise RuntimeError(
                "trail: timed out waiting for 2FA email code in jolyon.sandercock@gmail.com")
        log.info("trail: got code (length %d)", len(code))

        filled = False
        for sel in [
            'input[name="code"]', 'input[name="otp"]', 'input[name="verificationCode"]',
            'input[autocomplete="one-time-code"]',
            'input[type="text"][maxlength="6"]',
            'input[type="tel"][maxlength="6"]',
        ]:
            try:
                await page.fill(sel, code, timeout=4000)
                filled = True
                break
            except Exception:
                continue
        if not filled:
            inputs = page.locator('input[maxlength="1"]')
            try:
                count = await inputs.count()
                if count >= len(code):
                    for i, ch in enumerate(code):
                        await inputs.nth(i).fill(ch)
                    filled = True
            except Exception:
                pass
        if not filled:
            await _debug.dump_state(page, "trail", "2fa_code_input_miss")
            raise RuntimeError("trail: could not locate 2FA code input")

        submitted = await _try_click_any(page, [
            'button[type="submit"]',
            'button:has-text("Verify")',
            'button:has-text("Continue")',
            'button:has-text("Submit")',
        ], timeout_ms=4000)
        if not submitted:
            await page.keyboard.press("Enter")

    # ── Wait for the OIDC redirect chain to land on Trail ─────────
    try:
        await page.wait_for_url(lambda url: "trailapp.com" in url, timeout=30_000)
        log.info("trail: SSO complete, on Trail (url=%s)", page.url)
    except Exception:
        log.warning("trail: didn't reach trailapp.com after auth; url=%s", page.url)
        await _debug.dump_state(page, "trail", "post_auth_url_mismatch")


# ─── Public entry point ─────────────────────────────────────────────

async def scrape(
    *,
    username: str,
    password: str,
    date_from: date | None = None,
    date_to: date | None = None,
    pair_mode: bool = False,
) -> list[dict[str, Any]]:
    """Scrape Trail reports for the given range (default: last 14 days)."""
    date_to = date_to or date.today()
    date_from = date_from or (date_to - timedelta(days=14))

    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=not pair_mode)
        context_kwargs: dict[str, Any] = {}
        if STATE_PATH.exists():
            context_kwargs["storage_state"] = str(STATE_PATH)
        ctx = await browser.new_context(**context_kwargs)
        page = await ctx.new_page()

        try:
            await _oidc_login(page, username, password)

            # Reports list scraping is still TODO — implement during the
            # pairing run when we can see the actual DOM. Login + 2FA above
            # gets us to a fresh session with cookies for headless runs.
            log.warning("trail scraper: reports table scrape not yet implemented — "
                        "complete during pairing once login succeeds.")
            rows: list[dict[str, Any]] = []

            await ctx.storage_state(path=str(STATE_PATH))
            return rows
        finally:
            await ctx.close()
            await browser.close()


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--pair", action="store_true")
    parser.add_argument("--username", required=True)
    parser.add_argument("--password", required=True)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    rows = asyncio.run(scrape(
        username=args.username, password=args.password, pair_mode=args.pair,
    ))
    print(json.dumps(rows, default=str))
