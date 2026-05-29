# U229 — Dojo path decision: B (Playwright replace)

**Decided:** 2026-05-29 by Jo (hands-off batch directive).

**Chosen:** Path B — Playwright-driven auto-fetch from Dojo merchant dashboard.

**Rejected:** Path A (move python3 exec to bot-responder + keep manual CSV drop).

**Rationale:**
- Eliminates the manual CSV step entirely — one fewer thing on Jo's daily upload list (already up to 15 items per U227).
- Shares Playwright infrastructure with U230 (Trail) and future scraping work — single auth/cookie-management pattern.
- Daily Dojo data is the highest-business-value continuous stream (drives Mission Control work-cash tile); worth investing in robustness.

**First-run blocker:** Dojo dashboard auth requires Jo on-site to pair (likely 2FA SMS during initial Playwright session). Auth pairing is the single manual step in the build; once cookies are persisted to `storage_state.json` they survive subsequent runs until invalidated.

**Decommission:** `u135-dojo-inbox-sweep.sh` removed once Playwright path proven for 7 consecutive days.
