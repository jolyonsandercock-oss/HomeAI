# U156 — Trail integration via Playwright (Access aCloud OAuth)

**Prereqs**: Vault `secret/trail` populated 2026-05-21. Trail uses OAuth2/OIDC via Access aCloud SSO — `identity.accessacloud.com` → `web.trailapp.com`.

**Realm**: `work`.

**Remote vs in-person**: T1 pair flow needs Jo at console (DISPLAY=:0) for 2FA-style first login. T2-T4 are autonomous after pair.

**Why this sprint exists**: `u134-trail-poll.py` was built assuming a REST API at `api.trailapp.net`. There IS no public REST API for Trail customers — it's all OAuth-gated web UI. Replace with a Playwright scraper mirroring the Xero pattern.

## Tracks

### T1 — Pair script (~30 min — Jo needed at console)

**Build**:
- `scripts/u156-trail-pair.sh` — opens Chromium against `identity.accessacloud.com` with persistent profile at `/home_ai/data/trail-profile/`.
- Auto-fills email + password from Vault `secret/trail`. Jo completes any device-trust prompt manually.
- Detects post-login URL on `web.trailapp.com`. Verifies session by navigating to a Reports page.
- Asserts a `web.trailapp.com` cookie exists before exit (mirrors u128-xero-pair pattern).

**Acceptance**: profile contains live `web.trailapp.com` session cookies; manual subsequent navigation works.

### T2 — Reports scraper (~90 min — autonomous after T1)

**Build**: `scripts/u156-trail-scrape.py` — launches Chromium with persistent profile, navigates Reports pages, parses table rows.

Targets:
- Opening Checks (yesterday + today)
- Closing Checks
- Compliance scores per location
- Overdue tasks

Each row upserted into `trail_reports` (schema from V149).

**Acceptance**: ≥1 day of report data in `trail_reports`; idempotent on re-run.

### T3 — Daily cron (~15 min)

**Build**: `0 7 * * * /home_ai/scripts/u156-trail-scrape.sh` (after caterbook daily). Headed mode falls back to headless after first successful pair (mirror Xero pattern).

**Acceptance**: 3 days of successive cron runs produce same-shape data; selftest passes.

### T4 — Surface on /work/today (~30 min)

**Build**:
- `trail_overdue_actions` slug (already planned in U149 T5) — wire it to read from populated `trail_reports`.
- Add to `frontend_action_queue` UNION so overdue Trail tasks appear top of `/work/today`.
- Heartbeat: alert if no Trail data > 24h.

**Acceptance**: overdue Trail items render on `/work/today` within 60s of poll.

## Done criteria

- Pair flow works once with Jo at console.
- Daily cron populates `trail_reports` without manual intervention.
- /work/today action queue includes Trail overdues.

## Risk

Medium. Access aCloud anti-automation may bounce headless (like Xero's Akamai). Mitigation: keep headed mode as fallback (same pattern as Xero `XERO_HEADED=1`).

Related: [[feedback-trail-oidc-not-api]], [[project-u128-xero]].
