# British Gas portal — diagnosis + fix 2026-07-05

## Symptom (from cron log /home_ai/logs/u268-britishgas.log, monthly cron 0 7 3 * *)
The July 3 monthly run logged in fine and downloaded 15 bills for one
account, but then crashed with an unhandled `playwright._impl._errors.
TimeoutError: Page.goto: Timeout 30000ms exceeded` navigating to
`.../business/app/organisations` with `wait_until="networkidle"` — losing
the second account's invoices entirely for that run (see full-log.txt lines
40-73).

## Root cause
`scripts/u268-britishgas-scrape.py::run()` looped over both BG accounts:
```
for idx in range(2):
    try:
        total += await download_account(page, idx)
    except Exception as ex:
        print(...)
    await page.goto(".../organisations", wait_until="networkidle", timeout=30000)  # <-- NOT in the try/except
```
`business.britishgas.co.uk` is an SPA that keeps background polling alive,
so it never reaches Playwright's `networkidle` state — the goto reliably
times out. Because that specific `goto` sat **outside** the try/except that
protects `download_account()`, the timeout became an unhandled exception
that killed the whole script (and, on 2026-06-22, only got lucky because
the crash happened after the last account in that run's iteration order).

## Fix shipped
`scripts/u268-britishgas-scrape.py`:
- Wrapped the reorientation `page.goto(".../organisations", ...)` in its own
  try/except so a slow/never-idle reload can never abort the account loop.
- Changed `wait_until` from `"networkidle"` to `"domcontentloaded"` (fires
  once the shell HTML parses; the SPA's own polling never lets networkidle
  fire) with an explicit `wait_for_timeout(3500)` settle.

## Verification (1 login attempt — well within the 2-attempt cap)
Ran `/home_ai/scripts/u268-britishgas-portal.sh` once, live, end-to-end:
- `OUTCOME: LOGGED_IN`
- BOTH accounts processed this time (601526: 15 buttons, 385518: 15 buttons)
- `TOTAL_DOWNLOADED: 43` (up from 29 when only one account made it through)
- `INGESTED: 43`, exit code 0, no traceback
- New invoice picked up that wasn't in the prior partial run:
  `bg_385518_00_Invoice-15335840.pdf: 2026-06-26  £32.27`
- DB confirmed: `vendor_invoice_inbox` now has 94 British-Gas rows, most
  recent `created_at` = 2026-07-05 18:03 (today), most recent
  `invoice_date` = 2026-06-26 (see db-verify.txt).

No 2FA/CAPTCHA encountered — BG login is plain username/password (in Vault,
secret/britishgas) and completed normally both times observed.

## Login attempts used this session: 1 (successful)

## Verdict: FIXED + VERIFIED end-to-end
No further action needed from Jo. The existing monthly cron
(`0 7 3 * * u268-britishgas-portal.sh`) will run clean going forward.
`vendor_invoice_inbox` freshness for British Gas will keep updating monthly.
