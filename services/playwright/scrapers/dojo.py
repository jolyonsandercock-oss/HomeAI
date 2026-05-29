"""Dojo merchant dashboard scraper (U229 — Playwright replace path).

Credentials live in Vault under secret/dojo:
  username, password

2FA flow: Dojo offers email-based 2FA. We click the "email" option,
poll the jolyon.sandercock@gmail.com Gmail via google-fetch for the
just-arrived code, and submit it. No SMS / TOTP path needed.

Cookies persist to /home_ai/data/playwright-state/dojo-storage.json so
subsequent runs skip the auth handshake (Dojo's session cookie may still
expire after some weeks — re-pairing will be needed periodically).

Schema target: dojo_transactions (transaction_id is the unique key).
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
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from playwright.async_api import Page, async_playwright  # type: ignore

from . import _debug

log = logging.getLogger(__name__)

BASE_URL = os.environ.get("DOJO_BASE_URL", "https://account.dojo.tech")
STATE_PATH = Path(os.environ.get(
    "DOJO_STORAGE_STATE", "/home_ai/data/playwright-state/dojo-storage.json"))

# google-fetch lives on ai-internal alongside the playwright container.
GOOGLE_FETCH_URL = os.environ.get(
    "GOOGLE_FETCH_URL", "http://google-fetch:8011")
# Dojo MFA emails go to the Workspace admin account (admin@malthousetintagel.com).
GMAIL_ACCOUNT = os.environ.get("DOJO_2FA_GMAIL_ACCOUNT", "admin")

CODE_RE = re.compile(r"\b(\d{4,8})\b")  # widened — Dojo's code length unknown


# ─── Gmail polling for the 2FA code ──────────────────────────────────

def _fetch_dojo_code(after_ts: float, timeout_s: int = 180,
                     poll_every_s: int = 8) -> str | None:
    """Poll Gmail (via google-fetch) for a new Dojo 2FA email arriving
    after `after_ts` (epoch seconds). Returns the digit code or None on
    timeout.

    Strategy: list messages with `from:dojo newer_than:5m`, filter to
    those whose Gmail `internalDate` > after_ts, then look at the
    snippet — and fall back to the full body — for a 4–8 digit code.
    """
    deadline = time.time() + timeout_s
    seen: set[str] = set()
    after_ms = int(after_ts * 1000)

    list_q = urllib.parse.urlencode({
        "account": GMAIL_ACCOUNT,
        # Cast wide: dojo.tech, auth.dojo.tech (Auth0 host), or any dojo-noreply
        "q":       "from:(dojo OR dojo.tech OR auth.dojo.tech) newer_than:10m",
        "max_results": 5,
    })
    list_url = f"{GOOGLE_FETCH_URL}/messages?{list_q}"

    while time.time() < deadline:
        try:
            with urllib.request.urlopen(list_url, timeout=8) as r:
                msgs = json.loads(r.read()).get("messages", [])
        except Exception as e:
            log.warning("dojo 2fa: list_messages failed: %s", e)
            msgs = []

        # Newest first by internal_date.
        msgs.sort(key=lambda m: int(m.get("internal_date") or 0), reverse=True)

        for m in msgs:
            mid = m.get("id")
            if not mid or mid in seen:
                continue
            seen.add(mid)
            idate = int(m.get("internal_date") or 0)
            if idate < after_ms:
                continue  # arrived before we clicked

            # 1. Try the snippet first (cheap).
            snip = m.get("snippet", "") or ""
            for match in CODE_RE.findall(snip):
                if 4 <= len(match) <= 8:
                    log.info("dojo 2fa: code from snippet (msg %s)", mid)
                    return match

            # 2. Fall back to the full message body.
            try:
                full_url = f"{GOOGLE_FETCH_URL}/message/{GMAIL_ACCOUNT}/{mid}"
                with urllib.request.urlopen(full_url, timeout=8) as r:
                    body_json = json.loads(r.read())
                text = _flatten_body(body_json.get("payload", {}))
                for match in CODE_RE.findall(text):
                    if 4 <= len(match) <= 8:
                        log.info("dojo 2fa: code from full body (msg %s)", mid)
                        return match
            except Exception as e:
                log.warning("dojo 2fa: full body fetch failed for %s: %s", mid, e)

        time.sleep(poll_every_s)

    return None


def _flatten_body(payload: dict[str, Any]) -> str:
    """Collect text/plain (and text/html as fallback) from a Gmail payload tree."""
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
    """Try clicking the first selector that matches. Returns True if clicked."""
    for sel in candidates:
        try:
            loc = page.locator(sel).first
            await loc.wait_for(state="visible", timeout=timeout_ms)
            await loc.click()
            log.info("dojo: clicked %s", sel)
            return True
        except Exception:
            continue
    return False


async def _try_fill_any(page: Page, candidates: list[str], value: str,
                        *, timeout_ms: int = 4000) -> bool:
    """Try filling the first selector that matches. Returns True if filled."""
    for sel in candidates:
        try:
            await page.fill(sel, value, timeout=timeout_ms)
            log.info("dojo: filled %s", sel)
            return True
        except Exception:
            continue
    return False


async def _ensure_logged_in(page: Page, username: str, password: str) -> None:
    """Login + Dojo email-2FA flow.

    Steps:
      1. Goto BASE_URL — if cookies are still valid, we land on the
         dashboard and short-circuit.
      2. Fill username + password, submit.
      3. If a 2FA-method chooser appears, pick the email option.
      4. Click "send code" (if separate from method-pick).
      5. Note timestamp, then poll Gmail for the code via google-fetch.
      6. Fill the code, submit.
    """
    await page.goto(BASE_URL + "/", wait_until="domcontentloaded")
    # Let any auth redirect finish before deciding.
    await asyncio.sleep(1.0)

    url_lower = page.url.lower()
    on_login_url = (
        "/login" in url_lower or "/sign" in url_lower
        or "auth.dojo.tech" in url_lower or "/auth/" in url_lower
    )

    if not on_login_url:
        # URL doesn't look like login — double-check by looking for a
        # password input.
        try:
            pw_visible = await page.locator(
                'input[type="password"]'
            ).first.is_visible(timeout=4000)
        except Exception:
            pw_visible = False
        if not pw_visible:
            log.info("dojo: no login indicator — assuming existing session (url=%s)", page.url)
            return

    log.info("dojo: login required (url=%s) — waiting for SPA to render form", page.url)

    # The Dojo / Auth0 universal-login page is a SPA: the password field
    # can take several seconds to render. Wait explicitly.
    try:
        await page.wait_for_selector(
            'input[type="password"], input[name="password"]',
            state="visible",
            timeout=20_000,
        )
    except Exception:
        # Fall through — _try_fill_any will still dump state if the field
        # never appears.
        log.warning("dojo: password input didn't render within 20s; "
                    "continuing — debug dump will fire if fill misses")

    # ── Step 2: username + password ────────────────────────────────
    user_selectors = [
        'input[autocomplete="username"]', 'input[autocomplete="email"]',
        'input[type="email"]', 'input[name="email"]', 'input[name="username"]',
        'input#email', 'input#username',
    ]
    pass_selectors = [
        'input[autocomplete="current-password"]', 'input[autocomplete="password"]',
        'input[type="password"]', 'input[name="password"]', 'input#password',
    ]
    if not await _try_fill_any(page, user_selectors, username):
        await _debug.dump_state(page, "dojo", "username_fill_miss",
                                tried=user_selectors)
        raise RuntimeError("dojo: no username field matched — see debug dump")
    if not await _try_fill_any(page, pass_selectors, password):
        await _debug.dump_state(page, "dojo", "password_fill_miss",
                                tried=pass_selectors)
        raise RuntimeError("dojo: no password field matched — see debug dump")

    submitted = await _try_click_any(page, [
        'button[type="submit"]',
        'button:has-text("Sign in")',
        'button:has-text("Log in")',
        'button:has-text("Continue")',
    ])
    if not submitted:
        await page.keyboard.press("Enter")

    # ── Step 3: 2FA method chooser ─────────────────────────────────
    # Dojo presents a list of methods (e.g. email vs SMS). We force email.
    await page.wait_for_load_state("domcontentloaded", timeout=15_000)
    await asyncio.sleep(1.0)

    picked_email = await _try_click_any(page, [
        # Common patterns — broaden as needed during pairing
        'button:has-text("Email")',
        'button:has-text("email")',
        'label:has-text("Email")',
        'input[type="radio"][value="email" i]',
        'input[type="radio"][value*="email" i]',
        '[data-method="email"]',
        '[aria-label*="email" i]',
    ], timeout_ms=6000)

    if picked_email:
        log.info("dojo: chose email 2FA")
        # Some flows need a separate "Send code" / "Continue" press.
        await _try_click_any(page, [
            'button:has-text("Send")',
            'button:has-text("Send code")',
            'button:has-text("Continue")',
            'button[type="submit"]',
        ], timeout_ms=3000)
    else:
        log.info("dojo: no 2FA method chooser found — dumping for review and "
                 "assuming code already on its way")
        await _debug.dump_state(page, "dojo", "no_2fa_chooser_found")

    # ── Step 4–5: poll Gmail for the code ──────────────────────────
    code_request_ts = time.time()
    log.info("dojo: polling jolyon.sandercock@gmail.com for Dojo code (up to 3 min)")
    code = await asyncio.to_thread(_fetch_dojo_code, code_request_ts)
    if not code:
        await _debug.dump_state(page, "dojo", "2fa_email_timeout",
                                after_ts=code_request_ts)
        raise RuntimeError(
            "dojo: timed out waiting for 2FA email code in jolyon.sandercock@gmail.com")
    log.info("dojo: got code (length %d)", len(code))

    # ── Step 6: enter the code ─────────────────────────────────────
    code_selectors = [
        'input[name="code"]', 'input[name="otp"]', 'input[name="verificationCode"]',
        'input[autocomplete="one-time-code"]',
        'input[type="text"][maxlength="6"]',
        'input[type="tel"][maxlength="6"]',
    ]
    filled = False
    for sel in code_selectors:
        try:
            await page.fill(sel, code, timeout=4000)
            filled = True
            break
        except Exception:
            continue
    if not filled:
        # Some forms split the code across N single-char inputs.
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
        await _debug.dump_state(page, "dojo", "2fa_code_input_miss")
        raise RuntimeError("dojo: could not locate 2FA code input")

    # Tick "Remember this device for 30 days" — extends Dojo's cookie life
    # significantly, so we don't burn a 2FA round trip every scheduled run.
    remember_selectors = [
        'input[type="checkbox"][name*="remember" i]',
        'input[type="checkbox"][name*="trust" i]',
        'input[type="checkbox"][name="prompt" i]',
        '[data-testid*="remember"] input[type="checkbox"]',
        'label:has-text("Remember") input[type="checkbox"]',
        'label:has-text("remember") input[type="checkbox"]',
        'label:has-text("Trust") input[type="checkbox"]',
    ]
    ticked = False
    for sel in remember_selectors:
        try:
            await page.check(sel, timeout=3000)
            log.info("dojo: ticked 'remember device' via %s", sel)
            ticked = True
            break
        except Exception:
            continue
    if not ticked:
        # Try clicking a label whose text starts with "Remember" — labels
        # are commonly bound to the checkbox via for=…
        for label_sel in [
            'label:has-text("Remember this device")',
            'label:has-text("Remember device")',
            'label:has-text("Remember me")',
            'label:has-text("Trust this device")',
        ]:
            try:
                await page.click(label_sel, timeout=2000)
                log.info("dojo: clicked 'remember' label %s", label_sel)
                ticked = True
                break
            except Exception:
                continue
    if not ticked:
        log.warning("dojo: 'remember device' checkbox not found — dumping for review "
                    "(MFA will still submit; just no 30-day skip next run)")
        await _debug.dump_state(page, "dojo", "remember_device_checkbox_miss")

    submitted = await _try_click_any(page, [
        'button[type="submit"]',
        'button:has-text("Verify")',
        'button:has-text("Continue")',
        'button:has-text("Submit")',
    ], timeout_ms=4000)
    if not submitted:
        await page.keyboard.press("Enter")

    # Wait until we leave the auth host and land back on account.dojo.tech
    # (or any *.dojo.tech that isn't auth/login).
    try:
        await page.wait_for_url(
            lambda url: (
                "dojo.tech" in url.lower()
                and "auth.dojo.tech" not in url.lower()
                and "/login" not in url.lower()
                and "/sign" not in url.lower()
            ),
            timeout=20_000,
        )
        log.info("dojo: logged in (url=%s)", page.url)
    except Exception:
        log.warning("dojo: post-2FA URL didn't match dashboard heuristic; url=%s", page.url)
        await _debug.dump_state(page, "dojo", "post_2fa_url_mismatch")


# ─── Public entry point ─────────────────────────────────────────────

async def scrape(
    *,
    username: str,
    password: str,
    date_from: date | None = None,
    date_to: date | None = None,
    pair_mode: bool = False,
) -> list[dict[str, Any]]:
    """Scrape Dojo transactions for the given range (default: last 7 days).

    Returns rows matching the dojo_transactions schema:
      transaction_id, mid, site, address, location, transaction_date,
      transaction_time, transaction_type, amount, …
    """
    date_to = date_to or date.today()
    date_from = date_from or (date_to - timedelta(days=7))

    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=not pair_mode)
        context_kwargs: dict[str, Any] = {}
        if STATE_PATH.exists():
            context_kwargs["storage_state"] = str(STATE_PATH)
        ctx = await browser.new_context(**context_kwargs)
        page = await ctx.new_page()

        try:
            await _ensure_logged_in(page, username, password)

            # Navigation + table-scrape still TODO — implement during the
            # pairing run when we can see the actual DOM. The login + 2FA
            # flow above is enough to reach the dashboard with a fresh
            # cookie so storage_state.json gets written for headless runs.
            log.warning("dojo scraper: table-scrape not yet implemented — "
                        "complete during pairing once login succeeds.")
            rows: list[dict[str, Any]] = []

            await ctx.storage_state(path=str(STATE_PATH))
            return rows
        finally:
            await ctx.close()
            await browser.close()


# CLI entry for the pairing session.
if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--pair", action="store_true",
                        help="run headed for first-time auth pairing")
    parser.add_argument("--username", required=True)
    parser.add_argument("--password", required=True)
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    rows = asyncio.run(scrape(
        username=args.username, password=args.password, pair_mode=args.pair,
    ))
    print(json.dumps(rows, default=str))
