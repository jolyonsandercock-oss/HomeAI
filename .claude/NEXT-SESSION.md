# Next session — opening prompt (draft)

_Drafted 2026-05-30 end-of-session. Read `MASTER.md` first._

**Where we left off:** Large stabilisation day — root cause across the board was a
mid-May host-crontab reset that silently dropped pipeline jobs. Restored/repaired:
invoices (u35 chain + crons, P2 retired), TouchOffice→EPOS bridge, caterbook/tides/
workforce/dojo/heartbeat schedules, Telegram bot reactivation, Gmail RLS drops, P9
(google-fetch rewire), dead-letter drained. Created `MASTER.md` living reference +
nightly commit-log updater. Selftest green (51/0).

**Top focus next (MASTER.md §2):**
1. **Xero Sync (P3)** — only integration leaving an open loop (invoice ↔ accounting); freshness `never`.
2. **RLS-role connection migration (U147)** — services still run as `postgres` superuser; only material security item.
3. **Karl onboarding + mobile dress rehearsal (U154)** — needs the UX polish pass first.

**Open decisions for Jo:** Trail + Dojo scrapers are parked (broken/CAPTCHA) — revisit when convenient. Recipe/inventory economics (Phase 8) not started.

**Mid-flight / fragile to watch:**
- P9 fix validated only on replayed events — confirm the next *real* `document.received` processes clean.
- Heartbeat is now **6-hourly always-emit** — sanity-check the Telegram volume is what Jo wants.
- `booking-scraper.py` + `weather-sync.py` still run from the bot-responder `/app` writable layer → a `--force-recreate` wipes them (see `feedback-bot-responder-scripts-not-baked`).
