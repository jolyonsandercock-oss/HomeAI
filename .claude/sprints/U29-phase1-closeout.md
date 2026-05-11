# U29 — Phase 1 close-out (P3, P7, P10)

**Goal:** Flip Phase 1 from 73% (8/11 pipelines live) to 100% by clearing the
three user-OAuth-blocked pipelines. After U29, Phase 1 is done and U30
(Dashboard Refactor — already drafted in memory) is unblocked per its
trigger spec.

## Why this sprint exists

After U27 + U28:

| Pipeline | Status |
|---|---|
| P1  Gmail Ingest        | ✓ done |
| P2  Invoice (PDFs+Haiku)| ✓ done |
| P3  Xero Sync           | **blocked — needs OAuth** |
| P4  Bank CSV            | ✓ done |
| P5  TouchOffice EPoS    | ✓ done (U27) |
| P6  Caterbook           | ✓ done (U28) |
| P7  Cashing Up          | **blocked — needs Sheets OAuth** |
| P8  Nanny               | ✓ done |
| P9  Report Ingestion    | ✓ done |
| P10 Daily Digest        | **blocked — needs Telegram + SMTP** |
| P11 Monthly Partition   | ✓ done |

All three remaining blockers are credential / vendor-registration tasks
that require a human in front of the right browser tab. Once the creds
land in Vault, the wiring is mechanical (existing schema, existing
patterns).

## Scope (chunks)

| # | Chunk | Owner | Estimate |
|---|---|---|---|
| 1 | P3 Xero — register at developer.xero.com, OAuth Playground for both orgs, tokens → Vault | you | 30 min |
| 2 | P3 Xero — wire the existing workflow, enable, smoke-test invoice match (P2 → P3) | me  | 30 min |
| 3 | P7 Sheet — create the cashing-up sheet (cols A–J per SPEC Appendix C) | you | 10 min |
| 4 | P7 OAuth — Sheets scope on the `info` account → Vault | you | 5 min |
| 5 | P7 workflow — build the n8n flow (Schedule + Sheets read + validate + INSERT cashing_up) | me  | 45 min |
| 6 | P10 Telegram — BotFather → bot token + chat_id → Vault | you | 10 min |
| 7 | P10 SMTP — Gmail app password → Vault | you | 5 min |
| 8 | P10 workflow — build the daily 21:00 digest (summarises P2/P5/P6/P7 day's takings) | me  | 45 min |
| 9 | Phase 1 retro + flip phase1.yaml + phases.yaml to 100% | me  | 20 min |

**Total:** ~2h me + ~1h you. The OAuth flows can be done in any order —
each pipeline is independent.

## Dependencies (already in place)

| Dependency | Status |
|---|---|
| `homeai-google-fetch` multi-account ingest | ✓ live |
| Vault paths: `secret/xero/{trading,estates}` reserved | ✓ |
| Vault paths: `secret/google/info` for Sheets scope | ✓ (already used for Gmail) |
| Vault paths: `secret/telegram` + `secret/smtp/gmail` reserved | ✓ |
| Schema: `xero_invoices`, `cashing_up_records` | ✓ in SPEC |
| Existing n8n workflows skeletons (Pipeline 3 + 7 + 10) | ✓ scaffolded |

## Outputs

After U29:

- Phase 1 pipelines registry: 11/11 ✓
- `/pub` dashboard pulls live data from all 11 pipelines (TouchOffice +
  Caterbook already wired in U27/U28; this sprint adds P3/P7/P10 sources)
- `phase1.yaml`: all `blocked` items resolved
- `phases.yaml`: Phase 1 gate flips to `status: done`
- Daily Telegram digest at 21:00 — the first thing the user sees each evening

## Anti-scope

- Dashboard Refactor — that's U30 (memory `project_dashboard_refactor.md`)
- Authelia close-out — Phase 2 hardening
- CI Auto-Fix — Phase 2 (now possible since GitHub off-host-backup exists)
- Caddy reverse-proxy routes for /dashboard, /metabase, /auth — Phase 2
- Paperless-ngx — Phase 3 (needs Brother ADS-2800W on-hand)

## Risks

| Risk | Mitigation |
|---|---|
| Xero developer app needs vendor approval (can take days) | Register early in the sprint; other pipelines can land first |
| Gmail SMTP app password requires 2FA on the account | If `info@` has 2FA, generate the app password there; otherwise use `jolyon.sandercock@gmail.com` |
| Telegram chat_id discovery requires sending a test message first | Document the discovery step in the helper script |
| User-OAuth flows can be done out of order | Each pipeline writes to its own Vault path, no cross-deps |

## Helper scripts to write (chunk-local)

- `scripts/u29-xero-creds.sh` — prompt for `client_id`, `client_secret`,
  refresh_token per org → Vault
- `scripts/u29-sheets-creds.sh` — paste OAuth refresh token + sheet ID → Vault
- `scripts/u29-telegram-creds.sh` — prompt for bot token + chat_id → Vault
- `scripts/u29-smtp-creds.sh` — prompt for SMTP user + app password → Vault

Each follows the U27 `u27-touchoffice-creds.sh` pattern: idempotent,
silent password input + confirm, round-trip verify (no value echoed).

## Acceptance criteria

- [ ] `vault kv get secret/xero/trading` returns `refresh_token`
- [ ] `vault kv get secret/xero/estates` returns `refresh_token`
- [ ] P2 invoice + P3 match: a real invoice in `invoices` table cross-links
      to a real `xero_invoices` row within 5 min of receipt
- [ ] `vault kv get secret/sheets/cashing_up` returns `refresh_token` +
      `sheet_id`
- [ ] P7 daily run inserts ≥1 row into `cashing_up_records` for the
      previous day
- [ ] `vault kv get secret/telegram` returns `bot_token` + `chat_id`
- [ ] `vault kv get secret/smtp/gmail` returns `user` + `app_password`
- [ ] P10 fires at 21:00 and a Telegram message + email digest arrives
- [ ] `phase1.yaml`: all P3/P7/P10 items show `status: done`
- [ ] `phases.yaml`: Phase 1 gate `status: done`

## What carries forward to U30

- U30 = Dashboard Refactor (memory `project_dashboard_refactor.md`).
  Pre-condition "Phase 1 = 100%" satisfied by U29.
- Caddy reverse-proxy routes — promoted to U30 chunk OR deferred to
  Phase 2 hardening.
- Authelia bootstrap close-out — Phase 2.
- TouchOffice 3-year backfill — completes during this sprint (currently
  running, ~36 hours remaining).
