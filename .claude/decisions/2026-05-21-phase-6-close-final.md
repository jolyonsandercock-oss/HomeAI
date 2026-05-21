# ADR — Phase 6 closed

**Date:** 2026-05-21
**Status:** **Decided** (was Draft as of earlier today)
**Predecessor:** `2026-05-21-phase-6-kickoff.md` (kickoff), `2026-05-21-phase-6-close-draft.md` (draft).

---

## Decision: Phase 6 closes today.

Operational close-the-loop is delivered for the cost side. The hardening
stack (Phase 5) + operational surfaces + observability are all live,
healthy, and self-monitored.

## What Phase 6 ultimately shipped

### Stability infrastructure (U146–U151, U164)
- 3 pipeline noOp-skip / 0-rows / parse-fail bugs patched (Report
  Ingestion, Invoice, Nanny). 4th pipeline (Gmail Ingest) confirmed
  not vulnerable (responseMode=onReceived).
- `recover_stale_leases_v3()` with soft-recovery for terminal-by-design
  cases — events no longer dead-letter for noOp-skip patterns.
- 18 migrations recovered to git (V159-V190).
- Realm pivot FAMILY → PERSONAL completed across 465 CHECK constraints
  (0 family-only remain).
- DL threshold back to default 5.
- System auto-pause loop closed.

### Security (U147)
- V177 applied + pen-tested (trading_role / personal_role / owner_role
  cross-realm isolation green).
- Authelia FQDN + forward_auth working at
  `https://jolybox.tailc27dff.ts.net/`.
- 3 Authelia accounts: jo (owner), karl (manager), staff (general).
- /admin /private /build owner-only gated.
- Service connection-string migration deferred (Path A/B), not blocking
  Phase 6 close — flagged in `feedback_service_pg_user_audit`.

### Cost gateway (U143, U144, U148)
- Quota hard-mode active across all 4 tiers (P0=£0.90, P1=£1.05,
  P2=£0.63, P3=£0.42/day).
- 30-day spend: £0.69 (sub-£1/month operational scale).
- LiteLLM + Presidio HARD-FAIL on cloud-bound calls live.

### Operational surfaces (U132–U135, U138, U149–U150, U159–U162, U171)
- 139 active query_whitelist slugs (was 45 at start of session).
- Revenue close-loop: revenue_today / 7d / breakdown_by_day slugs +
  daily 09:00 narrative email cron.
- Menu performance: per-PLU sales surfaced (was placeholder despite
  32k rows of source data).
- Mortgage statements: vision-OCR pipeline for image-only PDFs;
  6 new periods extracted; loan 295178-07 now `complete`.
- Reviews: 14 ingested via email-notification parsing (not scraping —
  TripAdvisor was DataDome-blocked).
- Vendor intelligence: spend / trend / price-creep / reorder-cadence
  slugs surfacing real signal (£17k/90d to St Austell Brewery, etc.).

### Self-monitoring (U165, U166, U167, U168, U169)
- data_source_freshness slug + 15-min Telegram watcher: alerts on
  any stale ingest.
- 5 data quality recon slugs + 06:00 daily Telegram digest.
- Monthly DR restore drill (currently passes: 12/12 tables, RTO 36s).
- Cron self-healing: tracking + auto-retry within grace windows.
- Auto-generated docs: slug-catalog.md, data-sources.md, cron-jobs.md.

### Critical save
- U167 drill discovered `backup-nightly.sh` had been EXCLUDING staging
  (pg_dump + n8n + vault archives) for months. Fixed. All pre-fix
  snapshots are config-only; only c0a36bc3+ (2026-05-21-20:07) have
  usable DB backups.

## What Phase 6 explicitly deferred

| item | reason | next sprint |
|---|---|---|
| Service connection-string migration to RLS roles | high-blast; needs Jo's go | U147b in Phase 7 |
| UX polish series | needs Jo's eyes on rendered pages | dedicated UX phase |
| Karl onboarding + dress rehearsal | needs UX work first | Phase 7 |
| Mortgage paper scans for 2020-22 gaps | physical access | in-person packet |
| Trail Playwright pair | interactive 2FA at console | when convenient |
| Personal realm features | scope discipline (work first) | Phase 9 |
| 2nd review scraper hardening | low-priority (email-notification works) | as needed |
| Recipe / inventory economics | depends on TouchOffice PLU + recipe data | Phase 8 |

## Risk register going forward

- **Quota hard-mode** — 0 false-blocks in 7 days but ceilings tuned to
  current 30-day baseline. If usage grows 10x (e.g. Phase 7 staff
  adoption), P0 floor may need raising. The U165 cost slug catches it.
- **NOLOGIN roles** — RLS isolation depends on app-layer GUC discipline
  until U147b lands.
- **DataDome on TripAdvisor** — direct scrape gives 403. Email-
  notification path works but Trail-style fight could resume if
  TripAdvisor changes notification format.

---

# Phase 7 — Revenue side + staff readiness

## Scope

Two parallel tracks for Phase 7:

### Track A — Revenue close-the-loop (technical)
Phase 6 surfaced cost (invoices → matched → categorised). Phase 7 closes
the revenue side: bookings → covers → cash → recognised → reported.

- VAT-relevant line classification on revenue (touchoffice + caterbook).
- Per-room-type revenue mix (which rooms earn most £/night).
- Per-PLU profitability (revenue minus recipe cost).
- Bookings forecast → revenue forecast (next 28 days).
- Cash variance closing (the till_reconciliation 371 rows finally
  surfaced via UI).

### Track B — Staff readiness (organisational)
The gating items U157+U158 were deferred from Phase 6 pending UX work.

- UX sprint series (dedicated; Jo-driven prioritisation).
- Karl onboarding + 1-week dress rehearsal.
- Permissions matrix refined: higher-tier vs lower-tier "Staff".
- Broader staff rollout (5+ accounts).

Both tracks complete = Phase 7 closes.

## Phase 7 → Phase 8 outlook

- Phase 8: Customer-facing (booking widget, breakfast portal hardening,
  guest portal).
- Phase 9: Personal realm catch-up (postponed since 2026-05-21).
- Phase 10+: Multi-property scaling.

---

## Verdict

**Phase 6: ✅ Closed.** Selftest 50/0/0, all sources fresh, all 4 quota
tiers in hard mode, 24+ commits today, 5 sprints all autonomous.

**Phase 7: ✅ Opened.** First sprint = U173 (track A) once Jo prioritises.
