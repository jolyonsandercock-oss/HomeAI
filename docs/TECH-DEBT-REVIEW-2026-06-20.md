# Home AI — Technical Debt Register 2026-06-20

**Generated:** 2026-06-20 (read-only audit)
**Sources:** TECH-DEBT.md, SYSTEM_ARCHITECTURE.md §4/§5, audit-invariants.py output, crontab -l, Metis SDD progress ledger, live script inspection
**Invariant run summary:** 7 FAIL, 17 WARN (audit-invariants.py 2026-06-20)

---

## TOP 5 — Fix These First

| Rank | ID | One-liner | Why now |
|------|-----|-----------|---------|
| 1 | TD-002 | 94% invoices uncategorised — all per-category cost/GP/margin broken | Owner cannot see rolling COGS by dept; blocks the single most-requested report |
| 2 | TD-001 | Seven services connect as postgres superuser (BYPASSRLS) | Every write by these services bypasses all RLS entity isolation — a misconfigured service would corrupt cross-entity data |
| 3 | TD-010 | u95 invoice harvester cron references a script that doesn't exist | Cron silently fails every 06:50; invoice capture via events path is completely stalled |
| 4 | TD-007 | Hermes DeepSeek/GPT egress bypasses Presidio + ai_usage logging | PII can leave the system unredacted with no cost record; zero visibility into cloud spend from Hermes delegation |
| 5 | TD-020 | Alerting has a circular dependency on Vault | When Vault seals (incident 2026-05-26), Telegram alerts fail → sealed vault cannot page for its own outage |

---

## 1. Security / RLS

### TD-001 — Seven services connect as postgres superuser (BYPASSRLS)
**Status:** already tracked (TECH-DEBT.md §Phase2+; SYSTEM_ARCHITECTURE.md §4)
**Invariant:** INV-PG-SUPERUSER FAIL × 7 (docker-compose.yml lines 64, 338, 448, 586, 653, 679, 700)
**Impact:** All RLS entity_isolation + realm_isolation policies are bypassed for every write from these services; a bug writes to the wrong entity with no guard. BYPASSRLS is permanent for the session — not scoped to individual queries.
**Effort:** M (requires V177 role grants + env swap or SET ROLE per request; migration path documented as Path A/B in memory)
**Priority:** P0
**Note:** H5 flag RLS_ENFORCE_SET_ROLE exists but rollout blocked on grant-gap audit (see memory feedback_rls_set_role_drops_guc_defaults).

---

### TD-002 — Eight services write DB without app.current_entity GUC set
**Status:** new (invariant-only; SYSTEM_ARCHITECTURE.md mentions gap generically)
**Invariant:** INV-ENTITY-GUC WARN × 8 (auto-classify.py, critical-listener/listener.py, homeai-data-proxy/main.py, homeai-litellm/proxy_config.py, homeai-presidio/main.py, llm-router/main.py, playwright/generate_holidays.py, wa-bridge/main.py)
**Impact:** entity_isolation RLS is PERMISSIVE so missing GUC returns 0 rows on read (silent undercount) and writes land on entity 0 (no entity). Silent data loss / misattribution with no error.
**Effort:** S–M per service (SET LOCAL before each write block)
**Priority:** P0

---

### TD-003 — Vault root token in use; AppRole migration deferred
**Status:** already tracked (TECH-DEBT.md §Phase2+)
**Impact:** Long-lived root token has BYPASSRLS-equivalent Vault access. Rotation is manual; token compromise = full secret store access. n8n Vault credential (id 0wPA4DCDuehPC9Mf) also uses this token.
**Effort:** M (AppRole + rotate n8n credential)
**Priority:** P1

---

### TD-004 — init_placeholder HMAC bug in static_context_change trigger
**Status:** already tracked (TECH-DEBT.md §Phase2+); V4 migration drops original trigger but signature writes still exist in test fixtures
**Impact:** Violates "every event must be signed" build rule. Events with `payload_signature='init_placeholder'` cannot be integrity-verified.
**Effort:** S (dedicated fix step; must bypass RLS-controlled paths)
**Priority:** P1

---

### TD-005 — Five ports published on 0.0.0.0 (no bind IP)
**Status:** new (invariant-only)
**Invariant:** INV-PORTS WARN × 5 (docker-compose.yml lines 216, 423, 544, 552, 564 — ports 3000, 8004, 8002, 8006, 8007)
**Impact:** These ports are reachable on all host interfaces, not just the tailnet IP or localhost. A routing mistake exposes internal services to wider networks.
**Effort:** S (add `127.0.0.1:` or tailnet-IP prefix to port specs in docker-compose.yml)
**Priority:** P1

---

### TD-006 — docker.sock mounted read-only on one service (:ro does not block Engine API)
**Status:** new (invariant-only)
**Invariant:** INV-DOCKER-SOCK WARN (docker-compose.yml line 383)
**Impact:** `:ro` prevents writing the socket file but the Docker Engine API uses socket for read AND write calls. Any container with the socket can start/stop/exec other containers.
**Effort:** S (audit whether the service truly needs Docker access; remove or replace with scoped API)
**Priority:** P2

---

### TD-007 — Hermes DeepSeek/GPT egress bypasses Presidio + ai_usage logging
**Status:** already tracked (SYSTEM_ARCHITECTURE.md §3, §5 gap #7)
**Impact:** PII from emails/invoices can leave the system unredacted via Hermes delegation to DeepSeek. No cost record in ai_usage for these calls — total cloud spend is undercounted.
**Effort:** M (Presidio redaction proxy on the DeepSeek egress path; wiring ai_usage logger)
**Priority:** P0

---

### TD-008 — Authelia not live (tailnet is only real perimeter)
**Status:** already tracked (SYSTEM_ARCHITECTURE.md §4; TECH-DEBT.md §Phase2+)
**Impact:** Frontend, /admin, /private, /build rely solely on Tailscale membership for access control. No per-route OIDC enforcement. Authelia container exists but is "phase2 — NOT live."
**Effort:** L (turn on forward_auth in Caddy for all gated routes; test OIDC flows per route tier)
**Priority:** P2

---

### TD-009 — rent_payments has RLS enabled with no policy (deny-all for non-superusers)
**Status:** already tracked (TECH-DEBT.md §Phase2+; rls-policies.sql line 13)
**Impact:** Any non-superuser role (homeai_readonly, homeai_pipeline) gets zero rows from rent_payments. Rent pipeline cannot be built until a JOIN-based policy is added.
**Effort:** S (add entity_id policy via V7 column already added)
**Priority:** P2

---

## 2. Ops / Infra

### TD-010 — u95 invoice harvester cron points to a non-existent script
**Status:** new (crontab inspection)
**Evidence:** Crontab: `50 6 * * * cd /home_ai && bash scripts/u95-harvest-cron.sh 3`. File `scripts/u95-harvest-cron.sh` does not exist (confirmed: bash: No such file or directory in logs). `u95-harvest-all-invoices.py` exists but is not wired to the cron wrapper.
**Impact:** Invoice capture via the email/events path has been completely stalled. Every cron run exits silently with error. Emails pile up in vendor_invoice_inbox with no harvesting.
**Effort:** S (write or restore the missing shell wrapper; or wire the .py directly)
**Priority:** P0

---

### TD-011 — Duplicated cron entries (breakfast × 2, u163 × 2, weather-sync × 2, u250 × 2)
**Status:** already tracked (SYSTEM_ARCHITECTURE.md §4; crontab confirmed)
**Evidence (crontab):**
- `u160-breakfast-send.py` appears at `0 17` twice (once bare, once with `cd /home_ai`)
- `u160-breakfast-kitchen.py` appears at `0 6` twice
- `u163-reviews-simple.sh` appears at `0 */3` twice (different invocation styles)
- `weather-sync.py` at `30 7` twice (one `docker exec -i`, one `docker exec` without -i — the `-i` form slurps loop stdin)
- `u250-resume-watchdog.sh` at `*/10` twice (one commented DISABLED, one active at bottom)
**Impact:** Double-execution of breakfast emails (duplicates to Jo), review scrapes, weather sync. u250 watchdog may fire twice per cycle.
**Effort:** S (prune the 8 duplicate lines; confirm correct invocation form for weather-sync)
**Priority:** P1

---

### TD-012 — bot-responder and build-dashboard call Anthropic directly (bypass llm-router)
**Status:** already tracked (SYSTEM_ARCHITECTURE.md §5 gap #9 partially; audit-invariants WARN)
**Invariant:** INV-DIRECT-LLM WARN × 2 (services/bot-responder/responder.py, services/build-dashboard/main.py)
**Impact:** These calls bypass the £6/day hard cap enforcement in llm-router and the Presidio redaction gate. Budget overruns and PII egress are undetected. (bot-responder does log to ai_usage manually, but budget fail-closed is not applied.)
**Effort:** M (route via llm-router or litellm gateway; need to pass system/user context through)
**Priority:** P1

---

### TD-013 — build-dashboard passes raw body_text to LLM prompt
**Status:** new (invariant-only)
**Invariant:** INV-BODY-TEXT WARN (services/build-dashboard/main.py)
**Impact:** Raw email body text (potentially containing PII, credentials, or prompt-injection payloads) is included directly in model input. Should use body_text_safe (sanitised variant).
**Effort:** S (replace body_text with body_text_safe in the LLM call site)
**Priority:** P1

---

### TD-014 — Unpinned Docker images (:latest) on core services
**Status:** already tracked (TECH-DEBT.md §Phase2+)
**Impact:** `docker compose pull` or image expiry can silently change postgres, n8n, Metabase, Grafana behaviour. Non-reproducible deployments. One bad n8n update could break all active workflows.
**Effort:** S (pin each image to a specific digest or version tag; update in docker-compose.yml)
**Priority:** P2

---

### TD-015 — Orphaned Vault secret (secret/postgres-roles/metabase_db)
**Status:** already tracked (TECH-DEBT.md §Phase2+)
**Impact:** Dead secret creates confusion about which key to use; anyone following the wrong path will get a stale password. Low risk but wastes rotation attention.
**Effort:** S (vault kv delete after confirming nothing references METABASE_DB_PASSWORD)
**Priority:** P2

---

### TD-016 — restic backup password NOT in Vault; root-owned scripts excluded from backup
**Status:** already tracked (SYSTEM_ARCHITECTURE.md §4; memory feedback_backup_cannot_read_root_owned)
**Impact:** Restic password lives only in a file/memory; loss = unrecoverable backup archive. Root-owned scripts (vault-watchdog.sh etc.) silently excluded from nightly backup → data loss on host failure.
**Effort:** S (put restic password in Vault; change script ownership or use sudo-aware backup path)
**Priority:** P1

---

### TD-017 — set -uo pipefail (without -e) in 10+ scripts
**Status:** new (confirmed in Metis progress notes; widespread in scripts)
**Evidence:** At least 10 scripts use `set -uo pipefail` without `-e`: homeai-cron-guard.sh, metis-nightly.sh, metis-observe.sh, invoice-backlog-drain.sh, u216-mortgage-reocr-wrapper.sh, u272-dashboard-watchdog.sh, metis-seed-benchmark.sh, u119-staff-draft.sh, u274-touchoffice-headoffice-backfill.sh, hermes-proposal-watch.sh, and others.
**Impact:** A failing psql command echoes "success" and the script exits 0. cron-health sees no failure. Silent data loss / skipped writes. (Metis progress notes: "echo success even on psql error".)
**Effort:** S (add `-e` flag to each affected script; test for any intentional non-fatal commands that need `|| true`)
**Priority:** P1

---

## 3. Data Pipelines

### TD-018 — NatWest CSV sweep code exists but is unscheduled (no cron entry)
**Status:** already tracked (SYSTEM_ARCHITECTURE.md §2 ⚠️ UNSCHEDULED)
**Impact:** NatWest statement CSVs placed in natwest-inbox/ are never automatically ingested. Bank reconciliation relies on manual runs.
**Effort:** S (add cron entry pointing to u-natwest-inbox-sweep.sh — note: entry already exists in crontab as `25 7 * * *` for u-natwest-inbox-sweep.sh; verify the script actually processes the inbox correctly)
**Priority:** P1

---

### TD-019 — Dojo sweep u135 starved (no CSVs since ~2026-06-15)
**Status:** already tracked (SYSTEM_ARCHITECTURE.md §2 ⚠️ STARVED)
**Impact:** Dojo card settlement data is stale. Financial reconciliation, YouLend loan tracking, and cash-vs-card reporting are stale for the last 5 days.
**Effort:** S–M (diagnose: is the Dojo inbox email not arriving, or is u135 failing silently? Check inbox + logs; may need to restore email routing or CSV export from Dojo portal)
**Priority:** P1

---

### TD-020 — Alerting has a circular dependency on Vault
**Status:** already tracked (SYSTEM_ARCHITECTURE.md §4 ⚠️; memory feedback_alerting_circular_dep)
**Impact:** When Vault is sealed, Telegram alerts fail (bot creds are Vault-only). Vault sealing is the most disruptive incident class — and it silences its own alerts. Host-level vault-watchdog partially mitigates this (2026-05-28) but the alert-sink→notify-bridge wiring is still open.
**Effort:** M (cache Telegram token in an env file or host-side secret outside Vault; make notify-bridge use fallback)
**Priority:** P0

---

### TD-021 — V250 quarantine: document.received events pile up pending forever
**Status:** already tracked (SYSTEM_ARCHITECTURE.md §0 + §5 gap #4)
**Impact:** `claim_event_batch()` excludes `document.received` and `child.event.detected`. PDF attachment events are never claimed by any consumer. The working path (cron sweeps off-event) was built as a workaround. ~183 no-PDF invoices remain uningestable via events.
**Effort:** M (either write a consumer for document.received events, or officially tombstone these event types and drain pending rows)
**Priority:** P2

---

### TD-022 — Cap-on-Tap / YouLend not ingested (display-only)
**Status:** already tracked (SYSTEM_ARCHITECTURE.md §2 ❌)
**Impact:** YouLend merchant cash advance repayments and Cap-on-Tap credit card charges appear only on the frontend static display. They are not in bank_transactions or any reconciliation table. True net-of-loan cash position is unavailable.
**Effort:** L (establish CSV/API ingest for both; YouLend has no API — may require email-PDF parsing)
**Priority:** P2

---

### TD-023 — Clover ingest is manual-only (u78)
**Status:** already tracked (SYSTEM_ARCHITECTURE.md §2 ⚠️ manual-only)
**Impact:** Clover EPOS data (if used) is not automatically synced. Any Clover-sourced revenue data drifts stale.
**Effort:** M (automate u78 or establish a Clover webhook/CSV export)
**Priority:** P2

---

### TD-024 — J&R invoice line extractor silently drops "0 lines" result (not flagged)
**Status:** already tracked (SYSTEM_ARCHITECTURE.md §5 gap #10)
**Impact:** When a J&R invoice returns 0 line items (e.g., format mismatch), the extractor skips silently. The invoice shows no lines with no alert. Financial line-item completeness is unknown.
**Effort:** S (add a WARN log + insert a sentinel row or raise an alert when line_count=0 for a known-supplier invoice)
**Priority:** P2

---

## 4. Financial-Data Integrity

### TD-025 — 94% of invoices have NULL category_canonical (all per-category cost/GP broken)
**Status:** already tracked (SYSTEM_ARCHITECTURE.md §1/§5 gap #1; headline gap)
**Impact:** `v_daily_cost_vs_sales` per-category columns are ~£0; every invoice lands in `net_other`. The owner's primary request (rolling 7/30 GP by dept vs food/drink/labour/overhead) is completely blocked.
**Effort:** M–L (Metis categorisation loop is in shadow mode — needs autoapprove enabled + backfill run; then recurring sweep)
**Priority:** P0

---

### TD-026 — Three incompatible category vocabularies joined only by hand-maintained functions
**Status:** already tracked (SYSTEM_ARCHITECTURE.md §1/§5 gap #2)
**Impact:** `vendor_category_rules` (display-names + slugs mixed), canonical slug enum, `cogs_category_map` taxonomy — any new supplier requires updating three places. Mismatches cause silent miscategorisation.
**Effort:** M (consolidate vocabulary; migrate vendor_category_rules to use canonical slugs only; update vendor_category_canonical() accordingly)
**Priority:** P1

---

### TD-027 — Labour on-cost basis inconsistency (26.92% vs v_daily_labour_by_team 12.5%)
**Status:** already tracked (SYSTEM_ARCHITECTURE.md §1/§5 gap #5)
**Impact:** `v_daily_labour_by_team` recomputes at 12.5% (from staff_meta) vs the owner-anchored 26.92% basis in workforce_shifts.cost_estimate. Two views disagree on labour cost for the same period — any comparison silently produces wrong numbers.
**Effort:** S (update v_daily_labour_by_team to use the 26.92% on_cost_pct from static_context, matching the trigger logic)
**Priority:** P1

---

### TD-028 — bank_transactions has many exact-duplicate rows
**Status:** already tracked (memory feedback_bank_txn_duplicate_rows)
**Impact:** Any `SUM(amount)` without a dedup step overcounts. Currently requires `ROW_NUMBER() PARTITION BY (...)` defence in every query. No automated dupe-detection alert.
**Effort:** M (add a UNIQUE constraint on content key (bank_account_id, transaction_date, amount, description) after cleaning existing dups; or add the INV-DB-DUP invariant check to pre-push gate)
**Priority:** P1

---

## 5. Metis Self-Improvement Hardening

### TD-029 — test_04 omits rejection-suppression assertion (plan-mandated test gap)
**Status:** new (Metis SDD progress.md Task 4 minor)
**Impact:** The suppression behaviour (a conflicting proposal is rejected rather than applied) is untested in the automated suite. A future regression would go undetected until the digest shows unexpected proposals.
**Effort:** S (add one assertion to test_04_detect.sql checking that an existing rule suppresses a GAP proposal)
**Priority:** P2

---

### TD-030 — test_04 uses DO NOTHING (refresh/update branch of ON CONFLICT untested)
**Status:** new (Metis SDD progress.md Task 4 minor)
**Impact:** The DO UPDATE path (re-proposing an existing proposal with a fresh confidence score) is exercised only by the live detect script, never by the test suite. Silent regression risk if detect logic changes.
**Effort:** S (add test case that confirms DO UPDATE sets updated_at / confidence on re-detect)
**Priority:** P2

---

### TD-031 — test_05 doesn't assert revert_payload->>'site'; conflict-without-insert edge case
**Status:** new (Metis SDD progress.md Task 5 minors)
**Impact:** (a) revert_payload site field not asserted — a wrong site would not be caught. (b) Conflict-without-insert: if an existing `vendor_category_rules` row matches (domain_pattern, site) but was inserted by a different path, `metis-apply.sh` marks the proposal applied without inserting the intended row. Near-impossible for GAP proposals in practice, but latent for CONTRADICTION path.
**Effort:** S (add assertion to test_05; add a comment in apply script noting the edge case)
**Priority:** P2

---

### TD-032 — metis-nightly.sh --dry-run has side effects (observe/detect/measure still write live DB)
**Status:** new (Metis SDD progress.md Task 8 minor)
**Impact:** Running `metis-nightly.sh --dry-run` gives false confidence — it only suppresses the digest send. The observe, detect, and measure steps still write to `cognition.*` tables. Test_08 therefore has real DB side effects that cannot be cleanly rolled back.
**Effort:** S (add a `--dry-run` guard to the observe/detect/measure calls, or document prominently that --dry-run is digest-only)
**Priority:** P2

---

### TD-033 — Metis corrective detector realm hardcoded to 'work'
**Status:** new (Metis SDD progress.md Task 6 minor; also TD-035 below on same theme)
**Impact:** The corrective rule (fires when a rule is narrowed) hardcodes `realm='work'`. Latent bug for any future non-work realm pilot (e.g., personal/ARE invoices). Not a problem today because the pilot is work-realm only.
**Effort:** S (replace literal with a parameter or lookup from static_context)
**Priority:** P2

---

### TD-034 — Metis autoapprove created but NOT run and NOT cron-wired (precondition runs=4 < 7)
**Status:** new (Metis SDD progress.md Task 10)
**Impact:** The autoapprove script was created but no cron entry wires it in. The prerequisite (7 full observe→measure cycles) hasn't been met yet. Until autoapprove runs, every categorisation improvement requires a manual `metis-apply.sh` call — the self-improvement loop is not fully autonomous.
**Effort:** S (add cron entry for metis-autoapprove.sh once runs≥7; document the gate clearly)
**Priority:** P2

---

### TD-035 — gap detector hardcodes realm='work' and site='shared'
**Status:** new (Metis SDD progress.md Task 1 minor; deferred)
**Impact:** GAP detection only fires on `realm='work'` invoices. Personal/ARE invoice categorisation would never trigger gap detection even if they were onboarded.
**Effort:** S (parameterise; or document as work-realm pilot scope)
**Priority:** P2

---

## 6. Cron Hygiene

### TD-036 — gemma4-doc caller (invoice-pdf-date-extract.py) missing think:false
**Status:** new (code inspection)
**Evidence:** `scripts/invoice-pdf-date-extract.py` line 134 passes `"options": {"temperature": 0}` to ollama but does NOT include `"think": False`. The architecture doc and invoice-line-extract.py both document that gemma4 is a thinking model requiring `think:false` or output is empty.
**Impact:** The date-extraction sweep (cron `10 7`) silently produces empty output from gemma4-doc. Invoice dates are not populated by the local model, falling back (if any) to cloud or leaving invoice_date NULL.
**Effort:** S (add `"think": False` to the options dict in invoice-pdf-date-extract.py line 134)
**Priority:** P1

---

### TD-037 — weather-sync.py in crontab with `-i` flag in a while-read loop context
**Status:** new (crontab inspection; memory feedback_docker_exec_heredoc_i_trap)
**Evidence:** Two entries for weather-sync: `docker exec -i homeai-bot-responder python3 - < /home_ai/scripts/weather-sync.py` and `docker exec homeai-bot-responder python3 /app/weather-sync.py`. The `-i` form (stdin redirect) is the known "slurps loop stdin" trap.
**Impact:** Duplicate execution; the `-i` form may interfere with surrounding shell context depending on cron runner behaviour.
**Effort:** S (remove the duplicate; keep the non-stdin form `docker exec homeai-bot-responder python3 /app/weather-sync.py`)
**Priority:** P1

---

### TD-038 — u250-resume-watchdog.sh appears twice in crontab (one commented-disabled, one active)
**Status:** new (crontab inspection)
**Evidence:** Line `# DISABLED 2026-06-17 broken cron PATH, taken over by live session: */10 * * * * /home/joly/u250-resume-watchdog.sh` followed later by `*/10 * * * * /home/joly/u250-resume-watchdog.sh` (uncommented).
**Impact:** The "disabled" comment is ineffective — the script runs every 10 minutes from the second active line. If the intent was to disable it, it is not disabled.
**Effort:** S (remove the active line if still disabled, or remove both lines and the disabled comment if re-enabled from the live session)
**Priority:** P1

---

### TD-039 — ~10 shell scripts with set -uo pipefail without -e (cron context)
**Status:** new (see also TD-017 — same root cause, cron-specific impact)
**Evidence:** metis-nightly.sh, metis-observe.sh, u274-touchoffice-headoffice-backfill.sh, u272-dashboard-watchdog.sh, u119-staff-draft.sh, homeai-cron-guard.sh, metis-seed-benchmark.sh, metis-autoapprove.sh, invoice-backlog-drain.sh, u101-cron.sh, u32-cashing-up-parser.sh, u198-vault-and-restart-watch.sh, u216-mortgage-reocr-wrapper.sh, hermes-proposal-watch.sh
**Impact:** Cron sees exit 0 even if a psql command fails — cron-health-check.py marks the job healthy. Silent failure is undetected until downstream data quality checks catch it.
**Effort:** S (systematic: `grep -l "set -uo pipefail" scripts/*.sh | xargs -I{} sed -i 's/set -uo pipefail/set -euo pipefail/'`; then test for intentional non-fatal steps needing `|| true`)
**Priority:** P1
**Note:** Same underlying issue as TD-017; listed separately because the remediation is a cron-hygiene sweep, not a per-script audit.

---

### TD-040 — cron-health-check.py inlined duplicate SQL fingerprint (not using parameterized query)
**Status:** new (code inspection, cross-reference memory feedback_n8n_sql_param_collision)
**Evidence:** scripts/cron-health-check.py line 77 uses `ON CONFLICT (fingerprint) DO UPDATE`. This is a different system from n8n, so not the same bug, but the pattern warrants review for any `$N`-style collision risk in the same script.
**Impact:** Low — cron-health-check uses asyncpg which does not share n8n's pg-promise interpolation; but worth confirming no dynamic-SQL construction paths.
**Effort:** XS (verify; likely no action needed)
**Priority:** P2

---

## Accepted / By-Design Items (NOT real debt)

These items appeared as warnings in analysis but are intentional design decisions.

| Item | Why it is not debt |
|------|-------------------|
| **RLS `entity_isolation` PERMISSIVE when GUC unset** | Pre-existing project pattern; permissive is intentional for bootstrap paths. Services that genuinely need full-entity access (e.g., cross-entity reporting) rely on this. Enforcing would break legitimate queries. |
| **Metis inlined SQL (test literal 1800 vs script subquery)** | Adjudicated plan-mandated/acceptable. The 30-minute threshold is a policy value, not a computed one; the dual-maintenance burden is acknowledged in progress notes. |
| **V250 quarantine as architectural decision** | The new cron-sweep architecture is *by design* a replacement for the event path, not a workaround. The event bus approach is officially deprecated for ingestion. Draining pending events (TD-021) is cleanup, not a required fix. |
| **hermes_ro SELECT-only role** | Correct and intentional. Hermes should never write to the DB directly. |
| **Metis in shadow mode (not yet autonomous)** | By design until precondition (7 cycles) is met. Autoapprove gate is a safety feature, not debt. |
| **Vault TLS disabled** | Vault is on the internal Docker network only; Tailscale provides the external TLS layer. By-design for this deployment topology. |
| **`think:false` required for gemma4** | Model behaviour, not debt. The architecture doc documents this. TD-036 (the missing `think:false` in one caller) is real debt; the requirement itself is not. |
| **Authelia used only for dashboard access** | The forward_auth for the dashboard route IS live (`https://jolybox.tailc27dff.ts.net/dashboard/`). Phase2 full enforcement is deferred debt (TD-008). |
| **bot-responder logs ai_usage manually** | The service correctly logs tokens/cost to ai_usage; the issue (TD-012) is budget-cap enforcement, not logging. |

---

## Priority Summary

| Priority | Count | IDs |
|----------|-------|-----|
| **P0** | 6 | TD-001, TD-002, TD-007, TD-010, TD-020, TD-025 |
| **P1** | 13 | TD-003, TD-004, TD-005, TD-011, TD-012, TD-013, TD-016, TD-017, TD-018, TD-019, TD-026, TD-027, TD-028, TD-036, TD-037, TD-038, TD-039 |
| **P2** | 15 | TD-006, TD-008, TD-009, TD-014, TD-015, TD-021, TD-022, TD-023, TD-024, TD-029, TD-030, TD-031, TD-032, TD-033, TD-034, TD-035, TD-040 |

*(P1 count includes items TD-036–TD-039 which straddle Cron Hygiene; counted once each)*

**Corrected counts:**
- P0: 6 items
- P1: 14 items (TD-003, TD-004, TD-005, TD-011, TD-012, TD-013, TD-016, TD-017, TD-018, TD-019, TD-026, TD-027, TD-028, TD-036, TD-037, TD-038, TD-039 — 17 listed but some are cron hygiene subsets; see note)
- P2: 17 items

**Already tracked in TECH-DEBT.md / SYSTEM_ARCHITECTURE.md:** TD-001, TD-003, TD-004, TD-007, TD-008, TD-009, TD-011, TD-014, TD-015, TD-018, TD-019, TD-021, TD-022, TD-023, TD-024, TD-025, TD-026, TD-027, TD-028
**New (found in this audit):** TD-002, TD-005, TD-006, TD-010, TD-012, TD-013, TD-016 (partially), TD-017, TD-020 (partially), TD-029 through TD-040
