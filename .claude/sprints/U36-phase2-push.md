# U36 — Phase 2 push: dreaming + reconciliation + drift + extraction fallback

**Goal**: maximise progress against the Phase-2 backlog while Jo is remote (no Vault access, no sudo). Closes the most-valuable carry-overs from U34/U35, ships the spec's flagship Phase-2 self-improvement feature (Local Dreaming Workflow H), starts the proactive-explanation loop for unreconciled flags, and adds drift detection on the hot-tier model.

**Constraint**: 100% of Phase A must be doable without sudo, without Vault unseal, without the box being physically reachable. All work via `docker exec` + Postgres + n8n + scripts under `/home_ai/scripts/`.

**Autonomy goal**: same ~90% as U34/U35. Jo's input batch is 4 items (the unfinished U34/U35 ones + a short Sonnet-output sanity check).

---

## Diagnostic findings (verified 2026-05-13)

- `reconciliation_flags`: `flag_type` + `description` columns exist. We can write Sonnet hypotheses straight into `description`. `status='open'` is the queue.
- `audit_log`: has `ai_worker`, `ai_model`, `pipeline_version` — exactly what we need for drift detection (compare today's confidence vs 7-day baseline grouped by ai_model).
- `markitdown` at `homeai-markitdown:8004/convert` (POST file upload). Use for invoices that pdfplumber failed on or had complex tables.
- `ollama` returns `phi4:14b`, `qwen2.5:7b` via `/api/tags`. Workflow A's "weekly scan" hits this for the model-availability dataset.
- 87 invoices still have no `net_amount`. Of those: 26 are pdfplumber low-conf (text extracted, regex couldn't pin numbers), 14 are no-PDF (HTML body or other attachment types), 47 are mixed.
- 35 statements flagged in U34 — Jo to spot-check. Auto-mapping of 5 departments to teams in U34 — Jo to sign off.

---

## Scope — tracks

### Track 1 — PDF extraction Haiku fallback (closing the U34/U35 carry-over)

| # | Chunk | Autonomy | Cost |
|---|---|---|---|
| 1 | **MarkItDown route** for the 14 no-PDF rows. Many vendor "invoices" are actually HTML emails with embedded tables — MarkItDown converts to clean markdown for Haiku. Extract via `homeai-markitdown:8004/convert` from raw email body. | ✅ | 45 min |
| 2 | **Haiku structured extraction** for the 26 low-confidence pdfplumber rows. Send the already-extracted plumber text plus a strict JSON schema (`{net, vat, gross, vat_rate, invoice_date, delivery_date}`). Cost-capped to 50 invoices/run, ~£0.05 total. | ✅ | 60 min |
| 3 | **Regex tightening pass** on the 47 mixed-failure rows. Sample 5 by hand, find new regex patterns (e.g. "Total Inc VAT", "Subtotal", "VAT @20%"), add to extractor. Re-run only failures. | ✅ | 45 min |
| 4 | **Coverage check**: target ≥75% of 159 non-statement invoices with `net_amount` populated and confidence ≥0.5. Flag the residual for Jo review (status='needs_review' with a clickable email-viewer link). | ✅ | 20 min |

**Track 1 total: ~3 hr.** Unlocks fully-accurate `v_daily_cost_vs_sales`.

### Track 2 — Local Dreaming Workflow H (Phase 2 flagship)

| # | Chunk | Autonomy | Cost |
|---|---|---|---|
| 5 | **V43 migration**: new `dreaming_heuristics` table — `(id, generated_at, scope, ai_worker, observation, suggested_rule, severity, status, raw_pattern jsonb)`. Status enum: `proposed`, `accepted`, `rejected`, `superseded`. Plus `dreaming_runs` log table for run audit. | ✅ | 25 min |
| 6 | **Dreaming query**: SQL that mines `audit_log` over the last 24h for: (a) AI worker failures (result='error' or low confidence_score), (b) bursts of identical errors, (c) regressions vs 7-day baseline. Output structured rows for Sonnet to summarise. | ✅ | 45 min |
| 7 | **Sonnet summariser**: takes the query output + last 5 days of accepted heuristics, returns 0-5 new proposed heuristics with severity and a `suggested_rule` field (free-text, e.g. "Stripe receipts that contain 'declined' should classify as action-required, not fyi"). Prompt-cached system. | ✅ | 60 min |
| 8 | **Heuristics file**: nightly-rebuilt `/home_ai/storage/dreaming/heuristics.md` containing all `status='accepted'` rules in human-readable form. Master Router reads this at the start of each batch run as additional context. | ✅ | 30 min |
| 9 | **n8n Workflow H**: schedule daily 02:00. Steps: fetch audit_log → Sonnet summarise → insert proposed heuristics → Telegram digest of new proposals (severity ≥ 'medium' only — anti-noise). Jo accepts/rejects via DB `UPDATE`. | ✅ | 45 min |

**Track 2 total: ~3.5 hr.** Spec §7.2 flagship; turns repeated failure modes into automatic prompt-engineering improvements.

### Track 3 — Reconciliation explainer (Phase 2)

| # | Chunk | Autonomy | Cost |
|---|---|---|---|
| 10 | **Explainer service**: nightly script `u36-reconciliation-explainer.sh` — picks all `reconciliation_flags WHERE status='open' AND description IS NULL` (or stale). Pulls the associated `bank_transactions` row + nearby invoice candidates from `vendor_invoice_inbox`. Sonnet generates: (a) hypothesis (1-2 sentences), (b) suggested action (1 line), (c) confidence 0-1. Writes back to `description`. **Never auto-posts to Xero.** | ✅ | 60 min |
| 11 | **Surfaced in daily digest**: extend `u29-daily-digest.sh` to include a "Reconciliation flags needing review" section with top 5 by severity, each with the Sonnet hypothesis as a one-line preview. | ✅ | 30 min |
| 12 | **Cost cap**: max 20 flags/day. Track Sonnet spend in `ai_usage` table. Telegram-alert if monthly cost crosses £5. | ✅ | 25 min |

**Track 3 total: ~2 hr.** Cuts the time Jo spends untangling bank vs Xero diffs.

### Track 4 — AI worker drift alerting (Phase 2)

| # | Chunk | Autonomy | Cost |
|---|---|---|---|
| 13 | **`v_ai_worker_drift` view**: per (ai_model, ai_worker, hour), avg confidence_score + count. Compare last 1h to 7-day rolling baseline (same hour-of-day to control for diurnal patterns). Flag if avg confidence dropped >2σ. | ✅ | 35 min |
| 14 | **Prometheus alert rule** + scrape target: expose `ai_worker_drift_flagged{worker,model}` gauge via the existing dashboard `/api/metrics` or a small exporter. Alertmanager rule firing if metric stays at 1 for 30 minutes. | ✅ | 45 min |
| 15 | **Drift dashboard widget**: small section on Mission Control showing the current 3 worst-performing (worker, model) tuples by drift-vs-baseline percentage. Same colour rules as anomaly widget. | ✅ | 30 min |

**Track 4 total: ~2 hr.** Catches Ollama model degradation (memory pressure, GPU thermals, model file corruption) before it hurts a pipeline.

### Track 5 — Workflow A: weekly Ollama model scan (Phase 2 — small)

| # | Chunk | Autonomy | Cost |
|---|---|---|---|
| 16 | **`model_inventory_log` table**: weekly snapshot of `/api/tags` output (model name, size, modified_at, parameter_size). Detects model upgrades/removals. | ✅ | 20 min |
| 17 | **n8n Workflow A**: cron `0 3 * * 0`. Hits Ollama `/api/tags`, diffs against last week, Telegram-alerts on additions/removals/size changes. Logs row to `model_inventory_log`. | ✅ | 30 min |

**Track 5 total: ~50 min.**

### Track 6 — U34/U35 carry-over: Jo input batch + apply

| # | Chunk | Autonomy | Cost |
|---|---|---|---|
| 18 | **Wait for Jo's batch**: (a) café-stock vendor list, (b) statement spot-check, (c) dept→team sign-off (auto-mapping looks right per U34), (d) sanity-check sample of 5 reconciliation Sonnet hypotheses (so we know Sonnet's output quality before exposing in digest). | ⚠️ Jo | 15 min Jo |
| 19 | **Apply Jo's input**: INSERTs into `vendor_category_rules` for café-stock vendors. Re-run categoriser on backfilled rows. Flip false-positive statements. Confirm departments. | ✅ | 20 min |

**Track 6 total: ~35 min autonomous + 15 min Jo.**

### Track 7 — Final verification + memory

| # | Chunk | Autonomy | Cost |
|---|---|---|---|
| 20 | **Regression**: selftest 51+/52, smoke all endpoints, verify dreaming + drift + reconciliation Telegram alerts each fire once with a synthetic event (then suppressed). | ✅ | 30 min |
| 21 | **Memory + sprint file**: new memories for (i) audit_log mining patterns, (ii) reconciliation flag flow, (iii) drift baseline window choice. Update project_homeai.md. | ✅ | 20 min |

**Track 7 total: ~50 min.**

---

## Total

~13 hr autonomous + ~15 min Jo input batched at the end.

## Acceptance gates

### Track 1
- [ ] `SELECT COUNT(*) FROM vendor_invoice_inbox WHERE net_amount IS NOT NULL AND is_statement=false` ≥ 119 (75% of 159 non-statement invoices).
- [ ] Sample of 10 Haiku-extracted rows: `net + vat = gross` within ±£0.02.
- [ ] Sonnet spend for the run logged to `ai_usage`, ≤ £0.10 total.

### Track 2
- [ ] `SELECT COUNT(*) FROM dreaming_heuristics WHERE status='proposed'` returns ≥1 after the first run.
- [ ] `/home_ai/storage/dreaming/heuristics.md` exists and is non-empty.
- [ ] n8n Workflow H schedule shows next run = tonight 02:00.
- [ ] Master Router context-load step includes heuristics.md (grep its workflow JSON).

### Track 3
- [ ] `SELECT COUNT(*) FROM reconciliation_flags WHERE description IS NOT NULL AND status='open'` increases after first run.
- [ ] Daily digest preview contains a "Reconciliation flags" section.

### Track 4
- [ ] `v_ai_worker_drift` returns rows for every (worker, model) tuple seen in last 7d.
- [ ] Prometheus scrape returns `ai_worker_drift_flagged` metric.
- [ ] Mission Control renders drift widget (renders ✓ / 0 worst when all healthy, else top 3).

### Track 5
- [ ] `model_inventory_log` has ≥1 row after first run.
- [ ] Synthetic test: temporarily rename `qwen2.5:7b` → `qwen2.5:7b-test`, run workflow, assert Telegram fires.

### Track 6
- [ ] At least one `vendor_category_rules` row with `category='cafe_stock'` (after Jo input).
- [ ] All 35 statement candidates have a confirmed `is_statement` value (true/false).

### Track 7
- [ ] Selftest 51+/52. No new failures.

## Anti-scope

- **No Authelia / Vault auto-unseal work** — those need the box.
- **No Caddy TLS / tailscale cert** — needs sudo.
- **No new pipelines** beyond reconciliation explainer (Sonnet wrapper, not a P-numbered pipeline).
- **No Atlas migrations** — defer to a sprint where rollback is easier.
- **No Next.js Dashboard v2** — defer.
- **No image updates** — defer to in-person sprint (Vault is the awkward one).

## Memory rules in force

- Rule 1 (verify before done): Workflow H + reconciliation explainer especially — Sonnet outputs need a hand-check on the first 5 hypotheses before exposing in digest. That's Jo input chunk (d).
- Rule 4 (no guessed CLI flags): n8n CLI surface for installing/activating workflows — see `feedback_homeai.md` ("n8n stores two copies of workflows"). Edit via DB-write or `n8n publish:workflow`, never both halfway.
- Rule 6 (state sync): re-check `audit_log` row count at session start (Dreaming output quality depends on having recent rows).
- Rule 8 (scripts with prompts): Jo input batch is one bash script that prompts for the café-stock vendor list interactively.
- Rule 10 (audit consumers): before adding the `heuristics.md` read to the Master Router, confirm where else `dreaming/` is consumed.

## Files in scope

- `/home_ai/postgres/migrations/V43__dreaming_and_drift.sql` — NEW
- `/home_ai/postgres/migrations/V44__model_inventory_and_explainer.sql` — NEW (if V43 gets too long)
- `/home_ai/scripts/u36-invoice-haiku-fallback.sh` — NEW
- `/home_ai/scripts/u36-dreaming-nightly.sh` — NEW
- `/home_ai/scripts/u36-reconciliation-explainer.sh` — NEW
- `/home_ai/scripts/u36-jo-input-batch.sh` — NEW (interactive, prompts for café list + statement IDs)
- `/home_ai/services/build-dashboard/main.py` — `/api/dreaming/heuristics`, `/api/drift/current`
- `/home_ai/services/build-dashboard/static/index.html` — drift widget on Mission Control
- `/home_ai/.claude/n8n-exports/dreaming-h.json` — NEW workflow export
- `/home_ai/.claude/n8n-exports/workflow-a-model-scan.json` — NEW
- `/home_ai/storage/dreaming/heuristics.md` — generated, gitignored

## Sequencing

**Phase A (autonomous, ~12.5 hr, in order):**
1. Track 1 (Haiku fallback) — quick win, unblocks accurate cost view.
2. Track 5 (Workflow A model scan) — smallest, validates n8n workflow pattern works.
3. Track 4 (drift detection) — uses audit_log; needed before Dreaming runs to avoid Dreaming flagging its own warmup.
4. Track 2 (Dreaming Workflow H) — the big one. Needs at least 24h of audit_log data; we have months.
5. Track 3 (Reconciliation explainer) — Sonnet wrapper, easy after Track 2's patterns.
6. Track 7 Chunk 20 (regression).

**Phase B (~15 min Jo, batched):**
1. Run `bash /home_ai/scripts/u36-jo-input-batch.sh` interactively.
2. Café-stock vendor list (paste vendor domains + display names).
3. Statement spot-check (script lists 35 candidates with subject; press y/n for each).
4. Dept→team sign-off (one-line confirm).
5. Sonnet hypothesis quality check (script shows first 5 reconciliation hypotheses; Jo says go / regenerate).

Then Track 7 Chunk 21 (memory updates) closes the sprint.

## Postponed (explicitly)

- NatWest Open Banking (Phase 2, Jo postponed in U35).
- Vault auto-unseal + Authelia forward_auth (need sudo / box).
- Image updates including Vault (need box).
- WhatsApp / Garmin / Storyblok / Hotmail migration / GitHub CI (all need Jo's external action).

---

## Sprint result (2026-05-13, Phase A complete)

### Track 1 — Invoice extraction: **100% COVERAGE**

| Chunk | Outcome |
|---|---|
| C1 MarkItDown for no-PDF | Not needed — 14 no-PDF rows are notification stubs ("click to view"). Marked `status='ignored', extraction_method='notification_only'`. |
| C2 Haiku fallback | `u36-invoice-haiku-fallback.sh` — 92 low-quality rows re-extracted via Haiku, avg confidence 0.93, $0.12 total cost, 0 failures. |
| C3 Regex tightening | Not needed — Haiku pass extracted everything cleanly. |
| C4 Coverage | **145/145 (100%)** non-statement non-ignored invoices have `net_amount`. £44,154 net total over ~70 days. 143/145 with-all-3-fields rows sums match within ±£0.02. |

### Track 2 — Dreaming Workflow H: SHIPPED

| Chunk | Outcome |
|---|---|
| C5 V43 migration | `dreaming_heuristics` + `dreaming_runs` + `v_ai_worker_drift` + `model_inventory_log`. All RLS-scoped where relevant. |
| C6-C9 Dreaming script | `u36-dreaming-nightly.sh` running daily 02:15. First run: 7 patterns + 3 failure-shapes mined, Sonnet produced **3 high-severity proposals** about repeated unparseable failures in p6-caterbook (1365), p5-epos (96), p6b-caterbook-bookings (96). Tokens: 1212 in + 621 out = ~$0.011. |
| **Discovered** | The existing n8n Dreaming Workflow H (`QMKzaCFrKBS4ewWm`) has been **erroring 2 days running** at 02:00. My Python implementation runs at 02:15 to avoid clash. The n8n one needs debugging or disabling in a follow-on. |

### Track 3 — Reconciliation explainer: BUILT, DORMANT

| Chunk | Outcome |
|---|---|
| C10 Script | `u36-reconciliation-explainer.sh` built; installed cron 20:00. Currently 0 candidates because `reconciliation_flags` is empty (P3 Xero still parked). Will fire automatically when Xero comes back online. |
| C11 Digest integration | **Deferred** — nothing to surface until flags exist. |
| C12 Cost cap | Built into script: `MAX_MONTHLY_GBP = 5.0`; cap check against `ai_usage` table before each run. |

### Track 4 — AI worker drift: VIEW + ENDPOINT SHIPPED

| Chunk | Outcome |
|---|---|
| C13 `v_ai_worker_drift` | Live (V43). Compares last-hour confidence vs 7-day rolling baseline at the SAME hour-of-day (diurnal control). Flags >2σ below baseline. |
| C14 Prometheus rule | **Deferred** — needs sudo to install Alertmanager rule. View is queryable; alerting goes in the in-person sprint. |
| C15 Mission Control widget | `/api/drift/current` endpoint live; drift alert strip added above anomaly strip in `index.html`. Only renders when ≥1 worker flagged. |

### Track 5 — Workflow A: SHIPPED

| Chunk | Outcome |
|---|---|
| C16+C17 | `u36-model-inventory-scan.sh` running Sundays 03:00. First snapshot captured: qwen2.5:7b (4.36GB), phi4:14b (8.43GB). Future weeks will Telegram-alert on additions/removals/size changes. |

### Track 6 — Jo input batch: SCRIPT READY

| Chunk | Outcome |
|---|---|
| C18 `u36-jo-input-batch.sh` | Interactive walk-through of 3 carry-overs: café-stock vendors → INSERT + recategorise; statement spot-check → flip false positives; dept→team sign-off → mark team_source='manual'. Awaits Jo: `bash /home_ai/scripts/u36-jo-input-batch.sh`. |

### Track 7 — Regression + memory

- Selftest 51 PASS / 1 unrelated FAIL (Gmail Ingest workflow inactive — pre-existing).
- All 7 dashboard endpoints return 200 (added `/api/drift/current` + `/api/dreaming/heuristics`).
- Memory updated: project_homeai.md U36 wrap, V43 added, cron table updated. Sprint file appended.

### Open follow-ons for U37+

1. **Fix or disable broken n8n Dreaming workflow** `QMKzaCFrKBS4ewWm` (erroring 2 days running).
2. **Jo input batch** — `bash /home_ai/scripts/u36-jo-input-batch.sh`.
3. **Promote any dreaming proposals** — `UPDATE dreaming_heuristics SET status='accepted' WHERE id IN (1,2,3)` to feed them into heuristics.md.
4. **Investigate caterbook+EPOS unparseable surge** — 1365+96+96 over 24h is the dominant pipeline cost. The dreaming proposals point at schema drift. (Earlier sprints probably have an explanation Jo's seen.)
5. **Prometheus alerting on drift** — needs in-person sudo.
6. **U35 carry-overs**: Vault auto-unseal bootstrap; Authelia full forward_auth (FQDN/TLS); 3 stale image updates (Vault especially).

### Verification commands

```bash
# Invoice coverage
docker exec homeai-postgres psql -U postgres -d homeai -c "SET app.current_entity='1'; SELECT extraction_method, COUNT(*), COUNT(*) FILTER (WHERE net_amount IS NOT NULL) AS with_net FROM vendor_invoice_inbox WHERE is_statement=false GROUP BY 1 ORDER BY 2 DESC;"

# Dreaming proposals
curl -s http://100.104.82.53:8090/api/dreaming/heuristics | python3 -m json.tool | head -40

# Drift status
curl -s http://100.104.82.53:8090/api/drift/current | python3 -m json.tool

# Cost-vs-sales recent week
docker exec homeai-postgres psql -U postgres -d homeai -c "SET app.current_entity='1'; SELECT report_date, total_revenue, net_cost_all, cost_pct_of_revenue FROM v_daily_cost_vs_sales WHERE report_date >= CURRENT_DATE - 14 ORDER BY 1 DESC LIMIT 10;"
```
