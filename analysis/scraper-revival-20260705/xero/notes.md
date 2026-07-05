# Xero export — diagnosis 2026-07-05

## Symptom (from cron log /home_ai/logs/u128-xero-export.log)
"bills page never finished loading" rc=3, every day since ~2026-06-26.

## Repro
1. Read prior artefacts in /home_ai/data/xero-exports/*-NOEXPORT.png — all show
   the plain Xero login page ("Log in to Xero"), not a spinner or consent wall.
2. Ran once headless (normal cron path): bounced to login. Confirmed via
   xero-bills-2026-07-05-NOEXPORT.png (page title "Login | Xero Accounting Software").
3. Ran ONCE more in headed mode (DISPLAY=:0 XERO_HEADED=1), which the script's
   own comments claim "bypasses the Akamai bounce-to-login that hits headless
   runs" — i.e. reuses the existing persistent profile/cookies, no credentials
   typed. Result: IDENTICAL bounce to the plain login page (see
   post-login-bounce.png / .html). No Akamai/bot-challenge banner in the HTML —
   just the standard login form.

## Root cause
The persisted session in /home_ai/data/xero-profile has expired (session
cookies are stale / Xero's server-side session timed out). This is NOT the
headless-fingerprint (Akamai) problem the script anticipated — headed mode
reproduces the exact same bounce, which rules that out. It's a plain expired
session requiring a fresh interactive login.

## Login attempts used this session: 0
No credentials were typed (session reuse only, both headless and headed
attempts navigated with the existing cookie jar).

## Verdict: BLOCKED-JO-REQUIRED
Xero login requires 2FA (u128-xero-pair.sh is explicitly interactive:
"complete 2FA in the window" — SMS or authenticator app). This cannot be
scripted/bypassed per the hard safety rules.

**What Jo must do:**
1. On the host with DISPLAY=:0 available, run:
   `/home_ai/scripts/u128-xero-pair.sh`
2. Complete the Xero login + 2FA prompt in the Chromium window that pops up.
3. Once paired, the existing cron (`45 6 * * *` u128-xero-export.sh) should
   resume working automatically — no script changes made/needed. Optionally
   run once manually to confirm:
   `DISPLAY=:0 XERO_HEADED=1 /home_ai/scripts/u128-xero-export.sh`
   (verified this headed path is otherwise plumbed correctly and only fails
   on the expired-session bounce).

No code changes shipped for Xero — nothing was broken in the script; the
session simply needs re-establishing by a human because of 2FA.
