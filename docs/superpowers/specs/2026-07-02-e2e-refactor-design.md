# End-to-End Refactor Program — Design (Approach A: phased, observability first)

**Date:** 2026-07-02 · **Approved by:** Jo (approach + OCR direction) · **Status:** design
**Inputs:** 5-agent full-system review 2026-07-02 (pipelines, tech debt, model/OCR, data/memory, ops/security), `docs/TECH-DEBT-REVIEW-2026-06-20.md`, `docs/CONSOLIDATION-PLAN-2026-06.md`, `docs/DECISION-n8n-2026-06-20.md`.

## 1. Context and goals

The June consolidation shipped its keystones (pipeline registry, categorisation backfill, costs summary) but stopped short of closing the loop: watchdogs detect, nobody is paged, and silent exit-0 remains the dominant failure mode. The 2026-07-02 review found and fixed four live incidents that all fit that pattern (3-day Gmail/ollama outage, P6 dead 2.5 weeks, memory bridge dead 17 days, restic prune dead 25 days — every one already flagged by an existing watchdog).

**Goals:** (a) silent failures become pages; (b) the financial model becomes trustworthy end-to-end (dates, categories, counterparties); (c) the model/OCR stack exploits the W7800 and closes the extraction backlog; (d) the two known security holes (superuser DSNs, Hermes egress) close; (e) the system survives reboots and host loss; (f) the paper record (docs, registers, crontab) matches reality.

**Non-goals:** n8n retirement (CLOSED decision — bounded hybrid until ≥2026-12); Xero (blocked on vendor); Authelia full enforcement (accepted posture); rebuilding pipelines onto a new substrate.

## 2. Already done (2026-07-02 incident triage — precondition for this program)

- Gmail Ingest: root cause was a wedged ollama returning 503s since 06-30 (1,342/1,343 failures), not SQL. Recovered; the once-fired latent apostrophe bug in `INSERT email.classified` parameterized (`scripts/gmail-ingest-parameterize-classified.py`); 433 lost emails re-driven to success; 32 older stranded events recovered.
- Dead-letter re-drive un-no-op'd: new `dead_letter.redrive_count` column; hygiene script gates on it (`u-deadletter-hygiene.sh`).
- P6 Caterbook: two fixes — corrupted regex escaping (`p6-fix-parse-regex.py`) and report_date normalisation to ISO (`p6-fix-report-date.py`).
- 8 boot-race containers recreated with correct secrets (incl. authelia); non-interactive recreate recipe proven.
- Partitions: Jun–Aug 2026 + DEFAULT overflow created for the 10 partitioned parents that lacked them (events already maintained; 39 partitions created).
- restic HDD repo unlocked; retention prune run (2.7 GiB reclaimed).
- Hermes memory bridge fixed (mnemosyne CLI delete is session-scoped → direct guarded sqlite delete); 17 days of memory drift synced; phantom `~` dir removed.

## 3. Phase R0 — Close the loop (observability keystone)

Every detection must reach a human or a self-heal. Work items:

1. **Heartbeat coverage:** wrap every crontab job in `scripts/ops-run.sh` (records `ops.pipeline_runs`); register the missing ~50 jobs in `ops.pipeline_registry` with freshness SQL + SLA. Acceptance: `SELECT` shows every enabled registry row with a run in its SLA window; registry count ≈ crontab count.
2. **Daily digest:** one morning Telegram message (existing notify path) listing open `mart.exceptions` + firing `system_alerts` with ages, and "pipelines with no heartbeat in SLA". Stop discarding the freshness watchdog's stdout.
3. **Alert-row hygiene:** fix the Diag_* fingerprint-per-day bug (upsert like WatchdogN8nErrors); auto-expire resolved/stale rows. Acceptance: `system_alerts` firing rows = genuinely-live issues only.
4. **Schedule the auditor** (built, tested, never cronned): `30 5 * * *` + digest delivery; wire into pipeline_runs.
5. **Deep health probes:** ollama probe = tiny actual generation (the 503 wedge passed `/api/version` for 3 days); per-service HTTP probes into selftest for all 33 containers.
6. **Boot-race generalisation:** extend `u273-caddy-boot.sh` to recreate *every* tailnet-bound service after reboot (use the proven non-interactive secret harvest), or docker.service drop-in `After=tailscaled.service` + IP wait. Acceptance: simulated reboot leaves 0 dead containers, 0 dead port-publishes.
7. **`set -e` sweep** across the 143 `set -uo pipefail` scripts (mechanical + `|| true` audit per script).
8. **Partition maintenance function** extended to all partitioned parents (currently events-only); monthly cron already exists.
9. **Stuck-processing reaper:** events left `processing` >1h (e.g. by n8n restarts) reset to pending with a counter guard.

## 4. Phase R1 — Financial data completion

1. **Invoice dates:** add `think:false` to `invoice-pdf-date-extract.py` (TD-036, still unfixed; explains part of the 3,495 NULL `invoice_date` has-PDF rows); drain the backlog; alert on date-extract yield=0 days.
2. **Categorisation to >95% (2026):** extend `vendor_category_rules` for the residual ~19% of 2026 invoices; consolidate the three category vocabularies into the canonical slugs (TD-026); keep Metis as the ongoing loop (wire autoapprove when its 7-cycle gate is met).
3. **No-PDF invoices (422):** classify the backlog — resend-able (re-fetch via u125/u95), vision-OCR candidates, or formally tombstoned. Acceptance: 0 rows in limbo without a disposition.
4. **Counterparty resolver:** repair the empty `counterparty_anchor` + `counterparty_resolution_log` writes (provenance is currently unauditable), then flip bank-side from shadow to REVIEW mode.
5. **Bank dedup constraint:** UNIQUE on content key (account, date, amount, description) after cleaning the 5 residual dups; retire per-query ROW_NUMBER defences gradually.
6. **Dojo feed:** starved since ~06-19 — decide API-scrape vs CSV routine, revive, register with SLA.
7. **Line-extraction visibility:** alert when `extracted=0 AND pdfs_fetched_today>0`; flag per-vendor "0 lines" results (J&R class).

## 5. Phase R2 — Model & OCR stack

**OCR bake-off (Jo's direction: trial Mistral, also test gemma4-qat):**
1. Unify all OCR consumers behind `scripts/ocr/registry.py` (add a `local_vision` adapter wrapping the u281 path) so engine choice is one `system_state ocr.engine` row.
2. Benchmark on a fixed sample from the ~1,900-invoice low-confidence pile + the CamScanner mortgage set, scored by the existing arithmetic self-validation (|net+vat−gross|≤0.02) + field accuracy vs known-good invoices: **(a)** qwen2.5vl:7b (baseline), **(b)** qwen2.5vl:32b (pull; u276's own recommendation), **(c)** gemma4-qat31b vision, **(d)** Mistral OCR API (implement the existing `mistral_ocr.py` skeleton; Vault-gate the key; ~$0.001/page). Mistral trial runs on low-sensitivity supplier invoices only until the egress posture is decided; bank/mortgage docs stay local.
3. Winner becomes the bulk engine; Claude vision (u151b) stays as the escalation tier; re-run the drain over the reject pile.
4. **VRAM discipline:** qwen2.5vl:72b does not fit 48GB with KV cache — delete it; prune ~130GB of unreferenced weights (qwen3.5:9b, phi4:14b, spare gemma4 variants, duplicate 72b quant), keep one 72b text quant for off-peak A/B on 0-line invoices.

**Cloud→local migrations (all eval-gated, reversible via LiteLLM config):**
5. Invoice ladder: insert gemma4-qat31b tier before Haiku (biggest cloud line-item: 421 Haiku calls/fortnight).
6. LiteLLM classify caps (email/report/child, currently Haiku with caching that never engages — 2.26M uncached tokens/month): move to qwen2.5:7b or gemma4-qat31b; `cap_dreaming` first (lowest risk).
7. Keep on cloud: Opus compliance, Sonnet digest/cashflow/bot-responder (caching verified working).
8. **Telemetry:** local ollama callers (u281/u285/line-extract) write ai_usage rows (throughput/latency, £0) like the qwen ladder already does.

## 6. Phase R3 — Security

1. **Superuser DSN migration (U151b Path A):** per-service roles for the 7 compose DSNs (postgres-exporter, build-dashboard, google-fetch, playwright, wa-bridge, bot-responder, critical-listener); grant-gap audit first (touched-relations vs `role_table_grants` per service; verify both GUCs set on every SET ROLE path). Then extend `RLS_ENFORCE_SET_ROLE=1` beyond the build-dashboard canary; decide FORCE RLS per table; close the realm-GUC fail-open asymmetry.
2. **Hermes egress:** add a deepseek route to LiteLLM (`:8771`) → Presidio gate + ai_usage logging + spend-breaker visibility for free; point `~/.hermes/auth.json` at it. Closes TD-007.
3. Bind the five 0.0.0.0 ports to tailnet/localhost; audit the docker.sock mount; verify the GitHub repo is private (install `gh`).

## 7. Phase R4 — Resilience & DR

1. Compose healthchecks for the ~30 services lacking them; selftest §1 extended to all containers.
2. **Off-box data backup** (currently code-only goes off-host; HDD repo is the same physical box) + the first restore drill; escrow restic password + unseal keys per DR-RUNBOOK gaps; stale-lock auto-detection in the backup script.
3. Revive hermes-sentinel (dead since 06-23) with per-run heartbeat.

## 8. Phase R5 — Hygiene & docs truth

1. Crontab dedupe (u160×2, u163×2, weather-sync×2, rsync×2, u250 contradiction) + refresh the cron-guard snapshot; re-schedule the cron-doc generator.
2. Fix MASTER.md nightly append (missing `cd /home_ai`); archive TECH-DEBT.md/STATE.md/STATUS.md with supersession banners; refresh SYSTEM_ARCHITECTURE §2 (wrong in 4 places); update CONSOLIDATION-PLAN for the n8n decision; close the ~10 verified-stale debt/memory items.
3. Repo hygiene: `git mv` the 44 root one-off patchers to `attic/`; delete `.bak` files + root `__pycache__`; move `backups/` credential material out of the build tree; remove the duplicate markitdown compose service; commit or revert the live compose/Caddyfile drift (Ollama tuning is live-intended — commit it).
4. Storage: delete the rejected 6.7GB gguf, scraper-debug 691MB, duplicate PDF tars; drop `_backup_*` tables after verification date; rotate `u66-telegram-bot.log` (32MB).

## 9. Sequencing, risks, verification

- **Order:** R0 → R1 → R2, with R5 items interleaved as cheap wins; R3 after R0 (enforcement flips need the observability to catch breakage); R4 alongside R3.
- **Risks:** RLS enforcement is the highest-blast-radius change — canary-per-service with instant rollback via env; financial backfills follow [[feedback_financial_recon_discipline]] (cross-foot, assert totals, `_backup_*` reversibility); GPU contention from 32B vision — schedule drains off-peak; Mistral trial = deliberate, scoped PII egress on supplier invoices only.
- **Verification:** every phase lands with its acceptance checks run and quoted (no "should work"); registry/digest greenness is the meta-proof for R0; per-dept GP vs Jo's May anchors is the proof for R1; bake-off scores decide R2.
- **Open decision for Jo (deferred, not blocking):** permanent Mistral egress posture if it wins the bake-off — options: accept for supplier invoices only / redact-first / stay local.

## 10. Bot-instruction backlog (surfaced, separate from this program)

Three pending `bot_instructions` (2026-06-23/25): review-tracker + aggregator emails (#1161, partially addressed by the Expedia commits — verify), insurance email check (#1105), insurance reminders per property (#1096). Handle as normal sprint work, not refactor scope.
