# Dext export — diagnosis 2026-07-05

## Symptom (from cron log)
TimeoutError waiting for `button:has-text("Export all")` after 90s, daily
since ~2026-07-01. Cron log showed the generic playwright TimeoutError
traceback with no clear root cause.

## Repro (1 run, no credentials typed — pure session reuse)
Ran `/home_ai/scripts/u126-dext-export.sh` once. Captured
`dext-2026-07-05-NOBUTTON.png` — this is NOT a changed export UI. It is the
plain Dext login page ("Log in to Dext … Or continue using Google/Microsoft/
Apple/Xero/Intuit/passkey"), URL bounced to `https://app.dext.com/en/sign/in`.

The script's own login-bounce check (`if 'login' in page.url...`) was placed
**after** the 90s `wait_for_selector` for "Export all", so a session bounce
was always masked as "button never appeared" — the real cause (expired
persisted session in /home_ai/data/dext-profile) never surfaced in the logs.

## Root cause
Persisted browser session in /home_ai/data/dext-profile has expired. Same
failure class as the Xero portal (see ../xero/notes.md) — not a UI/selector
change at all.

## Fix shipped (headless-safe, no login involved)
Moved the login-bounce URL check to run immediately after `page.goto()`,
before the long Export-button wait, and widened the match to also catch
`/sign/in` (Dext's actual bounce path — the old check only matched literal
substrings "login"/"sign-in", which technically also matches "sign/in", but
now it also captures screenshot+HTML evidence and exits fast/clean).
File: scripts/u126-dext-export.sh

Verified: re-ran once (session-reuse only, 0 additional logins) — now fails
in 2.3s with `ERR: bounced to https://app.dext.com/en/sign/in — session
expired, re-pair` and exit code 2, instead of a 90s timeout + traceback.
This does not fix the underlying access (still needs re-pairing) but turns a
noisy, slow, misleading failure into an immediate, correctly-coded one so
future triage (and any cron-health alerting on exit codes) is accurate.

## Login attempts used this session: 0
(profile/session reuse only — no credentials entered)

## Verdict: BLOCKED-JO-REQUIRED
`u126-dext-pair.sh` is explicitly interactive ("Complete login + 2FA. Close
the window when done.") — cannot be scripted per hard safety rules.

**What Jo must do:**
1. On the console with DISPLAY=:0, run: `/home_ai/scripts/u126-dext-pair.sh`
2. Complete Dext login + 2FA in the Chromium window that opens.
3. Existing cron (`30 6 * * *` u126-dext-export.sh && u126-dext-parse.sh)
   resumes automatically — no further changes needed.
