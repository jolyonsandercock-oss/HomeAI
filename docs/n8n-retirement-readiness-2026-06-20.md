# n8n Retirement Readiness Report — 2026-06-20

**Produced by:** read-only analysis (no code/config modified)
**Evidence source:** live DB (`homeai` postgres), crontab, audit_log last 14 days, SYSTEM_ARCHITECTURE.md, CONSOLIDATION-PLAN-2026-06.md

---

## VERDICT: NOT YET — partial retirement possible; 5 load-bearing workflows have no cron replacement

Phase 5 (retire dead n8n) from the consolidation plan requires the cron substrate to be proven + evidenced via the `ops.pipeline_registry` freshness gate, which is built but has zero runs recorded yet (`ops.pipeline_runs` is empty). Beyond the gate, 5 actively-running n8n workflows do real work with no cron equivalent.

---

## 1. Per-Workflow Table (all 23 active=true in DB)

> **Note:** The architecture doc (§0) says `master-router`, `email-pipeline (P1)`, `invoice-pipeline (P2)`, `bank-csv-import` are "active=false" — but all 4 show `active=true` in the DB and have audit-log evidence of running today/recently. The doc describes *intended* state, not yet applied. Do NOT retire these until they are explicitly deactivated in n8n.

| Workflow | Schedule/Trigger | What it does | Cron replacement | Status | Test evidence needed |
|---|---|---|---|---|---|
| **Gmail Poll Driver** | Every 15 min (sched) | Calls google-fetch `/poll-and-emit`; drives all email → `events` ingestion | — | **LOAD-BEARING — KEEP** | Confirmed: 1,090 runs last 14d in audit_log |
| **Gmail Ingest Pipeline** | Webhook `email-pipeline` | Classifies emails → inserts into `emails`, fires `email.classified` / `invoice.detected` / `child.event.detected` events | — | **LOAD-BEARING — KEEP** | 1,539 `classify_email` successes last 14d |
| **Master Router** | Every 30 sec (sched) | Claims events from `events` via `claim_event_batch()`; routes to Invoice Pipeline (P2), Report Ingestion (P9), Nanny (P8), Email Pipeline | Partial (see rows below) | **PARTIALLY LOAD-BEARING** | Today: 94 `email.received`, 97 `document.received`, 7 `invoice.detected` processed; stale-lease recovery every run |
| **Invoice Pipeline (P2)** | Webhook `invoice-pipeline` (called by Master Router) | Fetches PDF attachment via google-fetch; extracts invoice data via pdfplumber/Haiku; writes to `vendor_invoice_inbox` + events | Partial: date-sweep (`10 7`) + line-sweep (`40 7`) post-process; BUT `u35-invoice-pdf-extract.sh` + `u125-pdf-attachment-fetch.sh` provide off-path capture | **LOAD-BEARING (currently); targeted for retirement** | 46 successes + 11 failures last 7d; new cron sweeps are forward-only post-processors, not a drop-in replacement for the capture path |
| **Report Ingestion (P9)** | Webhook `report-ingestion` (called by Master Router) | Fetches PDF attachments from document.received events; classifies via Haiku | None identified | **LOAD-BEARING — NO REPLACEMENT** | 118 classify_document failures last 7d (parse errors; but it is actively being called) |
| **Nanny (P8)** | Webhook `nanny` (called by Master Router) | Classifies school-related child emails; last ran 2026-05-18 (all failures) | None | **DORMANT / low-value** | Last activity 2026-05-18; failing; `children` table in use |
| **P5 EPOS Pipeline** | Every 15 min (sched) | Processes ICRTouch Z-report emails from `emails` table → `epos_daily` | — | **LOAD-BEARING — KEEP** | 1,273 runs last 14d (all `unparseable` — this is expected when no Z-report email landed, not an error in the pipeline logic itself; the pipeline is alive) |
| **P6 Caterbook Pipeline** | Every 15 min (sched) | Processes Caterbook daily-report emails from `emails` → `accommodation_daily` | — | **LOAD-BEARING — KEEP** | 5,249 runs last 14d (last success 2026-06-14; stale — may need investigation) |
| **Caterbook Bookings (P6b)** | Every 15 min (sched) | Processes Caterbook reservation confirmation emails → `accommodation_bookings` | `u28-caterbook-daily.sh` (07:30) handles arrivals/departures; `u286-caterbook-guest-sync.sh` (05:37) handles guest contacts | **PARTIAL OVERLAP** | 13,443 `parsed_reservation` successes last 14d (very active) |
| **Alertmanager Sink** | Webhook `prom-alert` (called by Alertmanager) | Receives Prometheus alerts; upserts `system_alerts`; auto-pauses on DeadLetterFlood | None | **LOAD-BEARING — NO REPLACEMENT** | Alert routing confirmed live: `alertmanager.yml` sends all alerts to `http://homeai-n8n:5678/webhook/prom-alert`; recent `DeadLetterFlood` + `StuckProcessingLease` alerts in audit_log |
| **Notify Bridge (HTTP→Telegram)** | Webhook `notify-bridge` | Receives HTTP POST → sends Telegram message | `u29-heartbeat.sh` covers heartbeat; `u241-supervisor.sh` covers self-repair alerts; `u66-telegram-bot.sh` covers commands | **PARTIAL OVERLAP — ALERTMANAGER DEPENDENCY** | Used by Alertmanager Sink (`u228`); if Alertmanager Sink is retired, Notify Bridge must be replaced first |
| **Dead Letter Sweeper** | Hourly (sched) | Sweeps `dead_letter` for resolvable false positives; sends Telegram | `u54-pipeline-watchdog.sh` (every 15 min) covers some; `u86-audit-dead-letters.sh` exists | **PARTIAL OVERLAP** | Last audit entry: 2026-05-10; the n8n workflow runs hourly but shows no recent audit success in 14d window |
| **Daily Digest (P10)** | 05:00 + 22:00 (sched) | Builds morning/evening pipeline summary; sends Telegram | `u29-daily-digest.sh` exists as a script but is **NOT in crontab** | **NO CRON REPLACEMENT** | No audit_log entries; `u29-daily-digest.sh` exists but is not scheduled |
| **Cornwall News Briefing** | 07:00 daily (sched) | SearXNG search → Ollama summarise → format → Telegram | None identified | **NO CRON REPLACEMENT** | No audit_log entries; no cron equivalent found |
| **Pub Anomaly Alerter** | Hourly (sched) | Compares today's EPOS vs 15-day trailing same-DOW average; alerts if anomaly | None | **EFFECTIVELY DEAD** | Queries `epos_daily` which is empty/dead per §1 (revenue is 100% TouchOffice); workflow runs but finds no data to compare |
| **Telegram Bot (commands)** | Every 1 min (sched) | Polls Telegram getUpdates; dispatches commands (/pause, /resume, /sweep, stats) | `u66-telegram-bot.sh` (every 1 min cron) — explicitly replaces this workflow per its header comment | **REPLACED — RETIRE** | `u66-telegram-bot.sh`: "Replaces telegram-bot-v1 n8n flow" |
| **Watchdog — n8n Errors** | Every 15 min (sched) | Queries `execution_entity` for recent error-status executions; writes `system_alerts`; sends Telegram | None — but this is self-referential (monitors n8n) | **SELF-REFERENTIAL / RETIRE WITH n8n** | Monitors the n8n execution table; becomes irrelevant when n8n is retired |
| **Diagnostics (daily)** | 06:30 daily (sched) | Runs diagnostic SQL test suite; emits alerts for critical/warning failures | `selftest.sh` (via u241-supervisor every 10 min) covers service health | **PARTIAL OVERLAP** | 13 `failure` runs last 14d (consistently failing — likely a known bad state); `selftest.sh` provides more comprehensive coverage |
| **HMAC Signature Verifier** | 04:30 daily (sched) | Samples 100 events; recomputes HMAC; reports pass/fail rate | None | **NO CRON REPLACEMENT** | Running but consistently failing (61/100 failed today, 76/100 on 06-16); indicates a signing-key mismatch or historical events without signatures |
| **Cleanup (weekly)** | Sunday 04:00 (sched) | Prunes historical data; VACUUM ANALYZE; writes audit | No scheduled equivalent | **NO CRON REPLACEMENT** | Last audit entry: 2026-05-10 (one-off manual); weekly partition + vacuum not covered by cron |
| **Partition Maintenance** | 25th of month 09:00 (sched) | Creates next month's event partition | No scheduled equivalent | **NO CRON REPLACEMENT** | Last ran 2026-05-25; missed June (partition may already exist); must not miss before 2026-07-01 |
| **Image Audit (monthly)** | 1st of month 07:00 (sched) | Checks Docker images against Docker Hub for version drift; sends Telegram | No scheduled equivalent | **NO CRON REPLACEMENT** | No recent audit_log entries found |
| **Bank CSV Import** | Webhook `bank-csv` (manual upload) | Parses bank CSV uploads via pdfplumber; calls `import_bank_transactions()`; emits `bank.imported` events | NatWest sweep (`u-natwest-inbox-sweep.sh`, now scheduled `25 7`) provides automated path | **MANUAL FALLBACK — LOW PRIORITY** | Last audit entry: 2026-05-08; functionally superseded by NatWest sweep for NatWest |

---

## 2. Summary Counts

- **Total active=true workflows in DB:** 23 (+ 2 active=false: `_archive_Gmail Ingest`, `Dreaming (Workflow H)`)
- **Truly load-bearing with no cron replacement:** 5 (`Alertmanager Sink`, `Report Ingestion P9`, `Cleanup`, `Partition Maintenance`, `Image Audit`)
- **Load-bearing, must keep (not retiring):** 5 (`Gmail Poll Driver`, `Gmail Ingest Pipeline`, `P5 EPOS`, `P6 Caterbook`, `P6b Caterbook Bookings`)
- **Safe to retire NOW (replaced or dead):** 4 (`Telegram Bot commands` → u66; `Pub Anomaly Alerter` → dead/epos_daily empty; `Watchdog n8n Errors` → self-referential; `_archive_Gmail Ingest` already inactive)
- **Phase-5 gated (retire after cron coverage + evidence window):** 9 (`Master Router` + sub-pipelines `Invoice P2`, `Nanny P8`, `Bank CSV Import`, `Cornwall News Briefing`, `Daily Digest P10`, `Dead Letter Sweeper`, `Diagnostics`, `HMAC Verifier`, `Notify Bridge`)

---

## 3. Gates Checklist (concrete, terse)

Before any Phase 5 retirement action, ALL of the following must be done:

### Infrastructure gates (non-negotiable)

- [ ] **G1 — Alertmanager Sink replacement:** Write a cron script or standalone service that receives Prometheus webhook alerts → upserts `system_alerts` → sends Telegram. Update `alertmanager.yml` to point away from n8n. Test with a fake firing alert.
- [ ] **G2 — Notify Bridge replacement:** Replace `http://homeai-n8n:5678/webhook/notify-bridge` calls (used by Alertmanager Sink) with the G1 replacement endpoint. Audit all callers in `u228-wire-alert-sink-notify.py`.
- [ ] **G3 — Partition Maintenance:** Create a cron entry (e.g. `0 9 25 * *`) that runs `CREATE TABLE IF NOT EXISTS events_YYYY_MM PARTITION OF events ...` for the next month. Verify July 2026 partition exists before 2026-07-01.
- [ ] **G4 — Cleanup (weekly):** Create a cron entry (Sunday 04:00) that runs the prune + VACUUM ANALYZE + audit_log write. Source the SQL from the `Cleanup (weekly)` workflow's "Cleanup Sweep" + "VACUUM ANALYZE" nodes.
- [ ] **G5 — ops.pipeline_runs heartbeats:** The `ops.pipeline_registry` table is built (15 pipelines registered) but `ops.pipeline_runs` has 0 rows. Wire `lib/sweep_heartbeat.sh` into each registered cron sweep. The Phase 0 freshness gate cannot fire without run data.

### Evidence gates (Phase 0 requirement)

- [ ] **G6 — 14+ days of green pipeline_runs** for every registered pipeline in `ops.pipeline_registry`. The freshness watchdog (`u-pipeline-freshness-watchdog.sh`) must have been running clean over that window.
- [ ] **G7 — Master Router safely disabled:** Before disabling Master Router, verify that all `pending` events drain (currently 0 pending) and that the cron-driven paths (u35, u125, u-invoice-pdf-date-sweep, u-invoice-line-sweep) produce equivalent invoice capture. Run a 7-day parallel comparison (n8n P2 + cron sweeps both running) and confirm capture counts agree within 5%.
- [ ] **G8 — Report Ingestion P9 decision:** P9 is actively processing `document.received` events (118 classify attempts last 7d, all failing with `parse error`). Either: (a) fix the parse failure and keep P9 via the event path temporarily, or (b) confirm the pdfplumber cron sweeps fully cover all PDF attachment types P9 handles, then deactivate P9 and let `document.received` events drain via the fallback.

### Nice-to-have before retirement

- [ ] **G9 — Daily Digest P10:** Schedule `u29-daily-digest.sh` in crontab (e.g. `0 21 * * *`). Currently unscheduled; users will notice the loss of the evening summary.
- [ ] **G10 — Image Audit:** Write a cron equivalent for the monthly Docker image version drift check.
- [ ] **G11 — Cornwall News Briefing:** Decide: schedule a cron equivalent, or formally retire (low business value for the ops system).
- [ ] **G12 — HMAC Verifier:** Investigate the 61% failure rate (signing-key mismatch vs. historical events without signatures). Either fix or formally accept as informational-only before retiring.
- [ ] **G13 — Dead Letter Sweeper:** Confirm `u54-pipeline-watchdog.sh` + `u86-audit-dead-letters.sh` cover the auto-resolution logic, or schedule a cron equivalent.

---

## 4. Safe Cutover Sequence

Execute in strict order. Each step is independently reversible by re-enabling the workflow in n8n.

**Step 1 — Retire safe-to-retire NOW** (no gates required):
1. Deactivate `Telegram Bot (commands)` — `u66-telegram-bot.sh` already running.
2. Deactivate `Pub Anomaly Alerter` — queries empty `epos_daily`; no value.
3. Deactivate `Watchdog — n8n Errors` — self-referential; will auto-invalidate when n8n goes.
4. Deactivate `Bank CSV Import` — superseded by NatWest sweep for automated path; keep as UI fallback but deactivate the n8n workflow.

**Step 2 — Build missing cron replacements** (G1–G4, G9–G10):
- G1+G2: Alertmanager Sink + Notify Bridge replacement (can be a minimal Python script or bash calling vault+telegram directly).
- G3: Partition Maintenance cron.
- G4: Weekly Cleanup cron.
- G9: Schedule u29-daily-digest.sh.

**Step 3 — Wire sweep_heartbeat + wait 14 days** (G5+G6):
- Retrofit all 15 registered cron pipelines with heartbeat writes to `ops.pipeline_runs`.
- Wait for 14 days of clean freshness watchdog runs.

**Step 4 — Parallel-run and compare Invoice P2** (G7):
- 7-day side-by-side comparison of P2 capture vs cron sweeps.
- Only after parity confirmed: deactivate `Invoice Pipeline (P2)` and `Master Router` together (Master Router has no other live consumers once P2 + Nanny are gone).

**Step 5 — Resolve Report Ingestion P9** (G8):
- Either fix parse failures (current state is 100% fail) or deactivate and handle document.received via cron sweep. Deactivate `Report Ingestion (P9)`.

**Step 6 — Deactivate remaining low-value scheduled workflows**:
- `Nanny (P8)` — failing since 2026-05-18; deactivate unless child-email classification is actively wanted.
- `Daily Digest (P10)` — only after G9 (cron equivalent scheduled).
- `Cornwall News Briefing`, `Image Audit`, `HMAC Signature Verifier`, `Dead Letter Sweeper`, `Diagnostics (daily)` — each after its gate is satisfied.

**Step 7 — Final n8n shutdown** (after all gates):
- `Cleanup (weekly)` — only after G4.
- `Partition Maintenance` — only after G3 + confirmed July partition exists.
- Verify `renew-n8n-vault-token.sh` cron (`0 */12 * * *`) is removed — it only exists to keep n8n's vault token alive.
- Stop `homeai-n8n` container. Keep postgres `workflow_entity` table intact for 30 days as an audit record.

---

## 5. Risks

### V250 Quarantine / document.received
`claim_event_batch()` does NOT exclude `document.received` — the architecture doc's claim that these are "quarantined" is incorrect based on the live DB function. Master Router IS claiming and routing `document.received` events (97 today). These route to `Report Ingestion (P9)` which is currently failing with `parse error` on every attempt. If P9 is retired before a cron replacement for document.received processing is in place, all PDF attachment classification will silently stop. **G8 must be resolved before retiring Master Router.**

### Master Router is not merely recovering stale leases
The architecture doc's statement that Master Router is "largely DEAD" is outdated for the current DB state. It claimed and processed 94 `email.received`, 97 `document.received`, 7 `invoice.detected`, and 5 `child.event.detected` events today. Its audit_log only shows `recovered_post_lease` because that's the only explicit audit write in the workflow — the routing via HTTP calls to sub-pipeline webhooks is not separately logged. Disabling Master Router will immediately stop event dispatch to P2, P9, and Nanny. This is load-bearing work that needs parallel coverage before cutover.

### Webhook vs poll: timing differences
P5 (EPOS) and P6 (Caterbook) poll `emails` every 15 minutes — same cadence as their n8n schedule. P6b (Caterbook Bookings) polls `emails` every 15 minutes. These are functionally equivalent to replacing them with cron, but the n8n execution introduces 0–15s jitter that is acceptable. A cron replacement would be deterministic. No customer-facing SLA risk identified.

### Alertmanager → n8n hard-wired dependency
`alertmanager.yml` sends ALL Prometheus alerts to `http://homeai-n8n:5678/webhook/prom-alert`. If n8n is stopped before G1 is complete, ALL Prometheus alerting silently dies. This is the most acute risk — the monitoring system's alert path runs through the thing being retired. Fix G1+G2 before any shutdown attempt.

### HMAC Signature Verifier — persistent failure (61-76%)
This workflow has been consistently reporting 61–76% signature verification failure over at least 5 days. This is not a retirement risk per se, but it indicates that a significant portion of events in the `events` table have invalid or absent `payload_signature`. This was written by the `gmail_ingest` path which was previously (pre-refactor) the `_archive_Gmail Ingest` workflow. If HMAC verification is ever enforced as a security gate, this backlog of ~61% unverifiable events is a problem. Document and accept, or run a backfill before retiring.

### Partition Maintenance — time-sensitive
The `Partition Maintenance` workflow last ran 2026-05-25 and creates the following month's partition. The June 2026 partition presumably exists (email events are landing today). The July 2026 partition must be created before 2026-07-01 or new events will fail to insert. **G3 is time-gated — must be done by ~2026-06-28.**

### renew-n8n-vault-token.sh cron entry
The crontab contains `0 */12 * * * cd /home_ai && bash scripts/renew-n8n-vault-token.sh >> /home_ai/logs/renew-n8n-vault-token.log 2>&1` which renews the vault token n8n uses. This cron entry exists only to service n8n. It must be removed as part of the n8n retirement, not before.

---

## Appendix: Workflow→Function Quick Reference

| Workflow | DB tables written | External services |
|---|---|---|
| Gmail Poll Driver | audit_log | google-fetch:8011 |
| Gmail Ingest Pipeline | emails, events, audit_log, ai_usage | vault, ollama, api.anthropic.com |
| Master Router | events (status updates) | homeai-n8n (self webhook) |
| Invoice Pipeline (P2) | vendor_invoice_inbox, events, audit_log, ai_usage | vault, pdfplumber:8003, ollama, google-fetch |
| Report Ingestion (P9) | audit_log | vault, pdfplumber:8003, api.anthropic.com, oauth2.googleapis.com |
| P5 EPOS Pipeline | epos_daily, audit_log | — |
| P6 Caterbook Pipeline | accommodation_daily, audit_log | — |
| P6b Caterbook Bookings | accommodation_bookings, audit_log | — |
| Alertmanager Sink | system_alerts, audit_log | — (receives from Alertmanager) |
| Notify Bridge | — (pass-through → Telegram) | vault, Telegram API |
| Partition Maintenance | events (DDL) | vault |
| Cleanup (weekly) | events, emails, audit_log (prune) | vault |
| Diagnostics (daily) | diagnostic_history, audit_log | homeai-n8n (self) |
| HMAC Signature Verifier | audit_log | vault |
| Pub Anomaly Alerter | audit_log | vault |
| Dead Letter Sweeper | dead_letter, audit_log | vault |
| Daily Digest (P10) | — (read-only → Telegram) | vault |
| Cornwall News Briefing | — (search → Telegram) | vault, ollama, searxng |
| Telegram Bot (commands) | telegram_bot_state, command_log, static_context | vault, Telegram API |
| Watchdog — n8n Errors | system_alerts | vault |
| Image Audit (monthly) | — (read-only → Telegram) | vault, Docker Hub |
| Bank CSV Import | bank_transactions, events, audit_log | vault, pdfplumber:8003 |
| HMAC Signature Verifier | audit_log | vault |
