# Home AI — End-to-End Review & Rectification Sprint Plan

**Date:** 2026-06-06 · Planning only (no implementation). Reconciles every known
failure / unfinished job from: this session's work, a live system sweep, MASTER.md
§2–§3, and auto-memory. Sprints **U244–U250**.

---

## Executive summary

The system is **healthy at the surface** — 34/34 containers up, `system.state =
running`, no dead-letter flood — but carries a layer of **half-finished migrations,
parallel/duplicate pipelines, accumulating alerts, and historical failed-event
backlogs**. Nothing is on fire; several things are quietly wrong.

**The single most urgent item is self-inflicted this session:** Invoice Pipeline P2
was deliberately deactivated + superseded on 2026-05-30 (MASTER §3), but this morning
it was revived, drained, and **left active with `invoice.detected` re-admitted** — so
it now runs in parallel with the canonical harvester, writing the legacy `invoices`
table and **spending Haiku on every new invoice event for output nobody sees.** Fix
first (U244).

Priority order: **U244 (invoice reconciliation, P0) → U245 (API resilience, P1) →
U246 (alert/failure triage, P1) → U249 (RLS security, P1) → U247/U248 (data
completeness, P2) → U250 (degraded integrations, P3).**

---

## PART A — Reconciled inventory

### A1. Invoice pipeline — two systems, one canonical (P0)
| Item | Evidence | Disposition |
|---|---|---|
| **P2 left active + `invoice.detected` re-admitted** | `workflow_entity` P2 `active=t`; claim excludes only document/child | **Deactivate P2, re-exclude invoice.detected** — restore MASTER §3 state. It duplicates the harvester and burns Haiku for the invisible `invoices` table. |
| **`invoices` table is legacy** (55 rows, P2-only, not in dashboard) | dashboard reads `vendor_invoice_inbox`; MASTER §3 "empty/legacy" | Decide: discard the 55, or one-off migrate to `vendor_invoice_inbox`. Lean discard (harvester re-captures the same emails). |
| **canonical_category vocab mismatch** | Haiku emits `stock/services/other/utilities`; `V233 home_ai.canonical_category()` expects `wet_purchase/dry_purchase/...` → most map to "Uncategorised" | Rewrite the mapping to the real extractor vocab. |
| **Harvester durability** | `u95-harvest-cron.sh` cron lacked `cd /home_ai` (broke 2026-05-30→06-06); fixed via catch-up (163 ingested, 106 extracted); cron-line fix **pending Jo's sudo** | Confirm cron line fixed; verify `u235-embed` is scheduled (coverage 130,304/130,305 implies yes, unconfirmed). |

### A2. API resilience / retry (P1) — partially shipped this session
| Item | Evidence | Disposition |
|---|---|---|
| **bot-responder retry change not live** | `responder.py` baked (no mount); container still `max_retries`=0 | Rebuild bot-responder image. |
| **Raw-HTTP Anthropic callers still no-retry** | `lib/README.md` list: u61(httpx,33×529), u47e(22), u120, u159, u66, u113, u151b, u161, u163, u216 | Retrofit to `claude_call` helper / SDK `max_retries=8`. |
| **u66-telegram-bot: 70,171 errors / 2 days** | httpx/httpcore connection exceptions, raw-HTTP caller | Investigate (retry/cooldown + cut log spam); likely transient-network + no-retry. |
| **Vault token rotation + renewer cron** | skipped in U243 pre-flight (`token_rotated:false`, `cron_activated:false`); 168h token works ~7 days, no auto-renew | Activate (re-run `overnight-preflight.sh` with admin token). **Time-bounded** — token expires ~2026-06-12. |
| **Embed loop Ollama retry** | `u235` logs-and-continues; idempotent re-run recovers (self-heals) | Low-priority: add a few Ollama retries before `continue`. |

### A3. Alerting & failure triage (P1)
| Item | Evidence | Disposition |
|---|---|---|
| **Stale-accumulating criticals** | `Diag_pipeline_failure_rate_24h`(9 fps), `Diag_firing_alerts`(8), `Diag_dead_letter_recent`(6), `Diag_system_state`(3) — daily snapshots never auto-resolve | Add auto-resolution/dedup; same class as the WatchdogN8nErrors fingerprint bug. |
| **WatchdogN8nErrors fingerprint bug** | memory `feedback_watchdog_n8n_alert_accumulates` | Upsert by fingerprint instead of new row. |
| **Failed-event backlog** | `email.received` 911 (0 recent), `document.received` 822 (72 recent 48h), `invoice.detected` 232 (0 recent), `child.event.detected` 32 | Mostly historical (vault-seal era). Classify reprocessable vs archive; reprocess the recoverable, archive the rest. |
| **Alert-sink → notify-bridge wiring** | memory `feedback_alerting_circular_dep` (open) | Complete wiring so alerts reach Telegram without the vault circular-dep. |

### A4. Pending user instructions (P2)
**10 pending `bot_instructions`** (AGENTS.md: surface at session start). Notable:
transfer reconciliation RERUN + send (#235/#231/#229), Dojo CSV import (#151),
bank statements (#168/#171), British Gas + utility invoice extraction
(#268/#324), NatWest PDF import acct 48885525 (#284), system-hardening review (#260).

### A5. Data completeness (P2)
- **Invoice review backlog**: `vendor_invoice_inbox` `needs_review`=1,242, `new`=414 (~1,656 actionable). Needs triage UI pass + the A1 category fix.
- **British Gas numeric acct harvest** (portal) — memory `feedback_british_gas_attribution`.
- **Mortgage scans vision-OCR re-pass** — 7 Principality PDFs, Tesseract returns only "CamScanner" — memory `feedback_mortgage_scans_camscanner_ocr`.
- **TouchOffice pre-2026 backfill fails** — memory `feedback_touchoffice_guard_backfill_collision`.

### A6. Security / RLS (P1)
- **Service → RLS-role migration (U147)** — `bot-responder` + `build-dashboard` still
  connect as `postgres` superuser → RLS bypassed. MASTER §2 calls it "the only
  material security item open." Path A (env swap + Vault) or Path B (per-request SET
  ROLE) per memory `feedback_service_pg_user_audit`.

### A7. Degraded integrations (P3)
- **Trail scraper (u215)** — login `no_2fa_chooser_found`; Playwright rewrite + re-pair.
- **Dojo live scrape** — CAPTCHA-blocked; manual CSV via u135 (accept or revisit).
- **Xero Sync (Pipeline 3)** — not live; invoice↔accounting loop open (blocked on API).
- **Reconciliation v5.4** — raw/staging/mart 3-adapter rewrite queued.
- **Qdrant unused** — running but only in a demo page; real retrieval is Postgres
  `search_vectors`. Wire in deliberately or decommission to free GPU-box resources.
- **selftest 51/52** — Gmail Ingest `QMKzaCFrKBS4ewWm` pre-existing FAIL (non-blocking).

---

## PART B — Sprint roadmap (U244–U250)

> Each sprint is independently shippable. Effort = focused engineering time.
> "Verify" steps follow AGENTS.md (smoke-test in the running system).

### U244 — Invoice pipeline reconciliation **(P0 · ~0.5 day)**
**Goal:** one canonical invoice path; stop the duplicate Haiku spend.
1. Deactivate P2 (`active=false`) + re-exclude `invoice.detected` from
   `claim_event_batch` (new migration; reverts V234). Restore MASTER §3 state.
2. Decide the 55 legacy `invoices` rows — discard (recommended) or migrate to
   `vendor_invoice_inbox`.
3. Fix `home_ai.canonical_category()` to the real vocab (stock→?, services→?,
   utilities→Utilities, other→Other) — confirm the bucket names with Jo.
4. Confirm `u95` cron line fixed (Jo's sudo) + verify `u235-embed` is scheduled.
**Acceptance:** P2 off; invoice.detected not claimed; only harvester→`vendor_invoice_inbox`
runs; categories resolve; no duplicate spend. **Do this first / now.**

### U245 — API retry/cooldown rollout **(P1 · ~1 day)**
**Goal:** no background job stalls on transient API errors.
1. Rebuild bot-responder image (apply the committed `responder.py max_retries`).
2. Retrofit the raw-HTTP Anthropic callers (A2 list) to `claude_call` / SDK
   `max_retries=8`, **starting with u66-telegram** (70k errors) — add retry + cut log spam.
3. Activate Vault token rotation + renewer cron (**before ~2026-06-12 expiry**).
4. (Opt.) add Ollama retries to the embed loop.
**Acceptance:** 529/connection retried with cooldown; u66 error rate collapses;
`vault token lookup-self` shows auto-renewal.

### U246 — Alerting & failed-event triage **(P1 · ~1 day)**
1. Fix alert accumulation (Diag_* + Watchdog) — upsert/auto-resolve by fingerprint.
2. Triage failed events: reprocess recoverable `document.received` (72 recent) +
   any retryable `invoice.detected`; archive the historical vault-seal-era backlog.
3. Complete alert-sink → notify-bridge wiring.
**Acceptance:** open-alert list = real current issues only; failed-event backlog
classified + reprocessed/archived.

### U249 — Service RLS-role migration **(P1 · ~1 day)** *(U147)*
Move `bot-responder` + `build-dashboard` off `postgres` superuser to per-realm
NOLOGIN roles (Path A env-swap, fallback Path B SET ROLE). The only material
security item. **Acceptance:** services connect as non-superuser; RLS enforced; selftest green.

### U247 — Pending instruction backlog **(P2 · ~0.5–1 day)**
Work the 10 `bot_instructions` (A4): transfer recon rerun+send, Dojo CSV, bank
statements, British Gas/utility extracts, NatWest acct-48885525 import.
**Acceptance:** `bot_instructions` pending = 0 (or each triaged with a reason).

### U248 — Data completeness **(P2 · ~1–2 days)**
1. Invoice review backlog (1,242 needs_review / 414 new) — triage pass (post-U244
   category fix).
2. British Gas numeric-acct portal harvest + utility invoice extraction.
3. Mortgage scans vision-OCR re-pass (7 Principality PDFs).
4. TouchOffice pre-2026 backfill fix.
**Acceptance:** utility/mortgage data extracted; review queue materially reduced.

### U250 — Degraded integrations decisions **(P3 · ~1–2 days)**
Per A7, each gets a **fix / accept / kill** decision: Trail (Playwright rewrite),
Dojo (accept manual CSV), Xero Sync (scope, API-blocked), Reconciliation v5.4,
**Qdrant (wire-in or decommission)**, selftest 51/52 (accept/fix).
**Acceptance:** no "degraded" item without a recorded decision.

---

## Recommended immediate action

**U244 step 1 is safe, reversible, and stops live waste** — deactivate P2 + re-exclude
`invoice.detected`. Recommend doing it now rather than waiting for the sprint, since
every new invoice email currently triggers a redundant Haiku extraction into an
invisible table. Everything else can follow the sprint cadence above.
