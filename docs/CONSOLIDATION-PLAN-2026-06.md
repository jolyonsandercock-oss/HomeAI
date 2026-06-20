# home_ai Consolidation Program — Option B (cron substrate + thin orchestration)

**Decision (Jo, 2026-06-19):** adopt cron fully; build the thin orchestration layer cron lacks; **keep the dead n8n dormant until cron is proven + evidenced**, then retire. No n8n GUI use, no sub-minute reactive needs (messaging only). See [[project_system_architecture]] + `SYSTEM_ARCHITECTURE.md`.

**Guiding principle:** *observability first.* You cannot safely prove cron works — or retire n8n — without measuring the freshness/success of every pipeline. So the registry + freshness alerting is the keystone, and it doubles as the evidence base for the n8n retirement gate.

**Sequencing logic:** Phase 0 (observability) unblocks everything and is the n8n-retirement evidence. Phase 3 (categorisation → costs summary) is the headline *business* value Jo asked for. Phases interleave: 0 → (1 ∥ 3) → 2 → 4 → 5(gated).

---

## PHASE 0 — Observability foundation (KEYSTONE) — P0
Goal: every pipeline's health is visible; silent failures become alerts; build the evidence base for retiring n8n.
- **0.1 `ops.pipeline_registry`** table: `name, kind(scrape/sweep/sync), script_path, schedule_cron, target_table, freshness_query, freshness_sla_hours, enabled, owner`. Seed from the crontab + ingestion map in the architecture doc.
- **0.2 `ops.pipeline_runs`** log + heartbeat convention: each sweep records `(name, started_at, finished_at, status, rows_affected, note)`. A tiny `lib/sweep_heartbeat.sh` helper sourced by every wrapper (also gives lockfile + `set -uo pipefail` + vault-token harvest in one place).
- **0.3 Freshness watchdog** cron: checks each registered pipeline's `freshness_query` vs `freshness_sla_hours`; breach → `mart.exceptions` + Telegram. Extends/replaces `u165-freshness-watcher`.
- **Risk:** low (additive). **Evidence gate output:** a dashboard/query showing N days of green per pipeline = the proof to retire n8n in Phase 5.

## PHASE 1 — Cron substrate hygiene — P1 (cheap)
- **1.1** De-dupe the crontab (remove duplicated lines: breakfast, weather-sync, u163, u250). Snapshot crontab first.
- **1.2** Retrofit existing + new sweeps onto the `lib/sweep_heartbeat.sh` convention; register all in `ops.pipeline_registry`.
- **Risk:** low. Do alongside Phase 0.

## PHASE 2 — Fix the now-visible broken/silent feeds — P1
(The registry will make these scream; fix in priority order.)
- **2.0 google-fetch DNS (ROOT CAUSE, READY TO APPLY) — the #1 lever.** google-fetch hits intermittent Docker-DNS "Temporary failure in name resolution" to googleapis.com, silently stalling ALL invoice/attachment fetches → u95 broken, u125 PDF-fetch 8d stale, line backfill dropping ~183/batch. **Fix:** add a `dns:` block to the `google-fetch` service in docker-compose.yml (right after `networks: [ai-internal, ai-egress]`), mirroring n8n's working config:
  ```yaml
      dns:
        - 127.0.0.11   # Docker embedded resolver first
        - 1.1.1.1
        - 8.8.8.8
  ```
  Then `docker compose up -d google-fetch` (recreate), verify a few `/attachment` fetches succeed without DNS errors, re-anchor `scripts/.audit-baseline.txt` if compose line-drift trips it. **DO WHEN google-fetch IS IDLE** (not while the line backfill is using it). Mitigation already shipped: retry-with-backoff in the extractors so transient blips no longer drop invoices.
- **2.1 u95 harvester** — verify/restore (invoice capture path); confirm it's the live capture or formally supersede with the gmail-ingest path. Likely recovers once 2.0 is done.
- **2.2 NatWest sweep** — verify the content-dedup guard is safe, then **schedule it** (cron) — currently unscheduled.
- **2.3 Dojo feed** — DECISION NEEDED: build the `api.caterbook`-style Dojo API scraper, or resume CSV drops. Starved since ~06-15.
- **2.4 Line extractor** — flag J&R "0 lines" for review instead of silent drop (my code; cheap).

## PHASE 3 — Financial correctness + the costs summary — P0 (headline business value)
- **3.1 Invoice categorisation** (unblocks everything financial):
  - Consolidate to ONE canonical taxonomy (the `category_canonical` slugs); document the rules→canonical→cogs_map chain; deprecate the redundant vocabularies over time.
  - Extend `vendor_category_rules` for the top uncategorised vendors (covers most of the £497k); backfill `vendor_category`/`category_canonical` for the ~1,035 NULL 2026 rows (rules-based, GPU-free; LLM fallback only for genuinely unknown vendors). Mappings: St Austell→Beverage(bar); J&R TOM106→Food(kitchen)/MAL125→cafe_stock; Forest/Westcountry/Total Produce/Dole/Kingfisher/Bidfresh/Adam Moralee/Oana Stirban→Food(kitchen); Western Supply→repairs_maintenance; utilities→utilities; cafe phone/electric/water→utilities/overhead.
  - Forward sweep so new invoices auto-categorise. → lights up `v_daily_cost_vs_sales`.
- **3.2 Labour basis fix** — `v_daily_labour_by_team` to use the 26.92% on-cost basis (`cost_estimate`), not the stale 12.5%.
- **3.3 Costs summary** `mart.costs_summary` (refreshed nightly): per day + **rolling 7-day & 30-day average AND total** for: revenue (total + by dept bar/kitchen/cafe), food spend (kitchen), drink spend (bar), cafe spend, labour (on-costed), overhead (repairs+utilities+software+other); derived **GP overall + by department**, cost ratios, and residual after labour+overhead. Income-vs-spend on both 7 and 30-day windows. Built on the now-live `v_daily_cost_vs_sales` + corrected labour.
- **Risk:** medium (financial correctness — cross-foot/assert totals per [[feedback_financial_recon_discipline]]).

## PHASE 4 — Security & cleanup — P1/P2
- **4.1 Hermes DeepSeek/GPT egress** through the gateway (Presidio redaction + `ai_usage` logging). Security: PII currently leaves un-redacted.
- **4.2** Hygiene: markitdown defined-twice, `epos_daily`/`v_uncategorised_summary` documented-as-dead.

## PHASE 5 — Retire dead n8n — GATED on Phase 0 evidence
- Only after the registry shows the cron pipelines healthy for an agreed window (e.g. 2–3 weeks green): delete `master-router`, `email-pipeline`(P1), `invoice-pipeline`(P2), `bank-csv-import` + the event-claim machinery they depend on. **KEEP `gmail-ingest`, P5 EPOS, P6 Caterbook** (live, reactive email path Jo relies on). Until the gate: leave everything dormant (Jo's instruction).

---

## Accept / Dismiss (no work)
- Alerting↔vault circular dep — mitigated by host `vault-watchdog` timer. **Accept.**
- Authelia phase2 not-live — tailnet is the perimeter for a single operator. **Accept** (2FA = defence-in-depth, deferred).
- Superuser DB connections (BYPASSRLS) — known/planned (U151); **accept for now** on the private tailnet.
- `epos_daily` empty, `v_uncategorised_summary` misnamed — **document as dead**, optional drop later.
- gemma4 `think:false` — **verify** our extractors are safe, document the convention.

## Concurrent work + live state (2026-06-20, for Metis / future sessions)
Two Claude instances active. This branch's invoice/finance/ops work is **LIVE** (not shadow):
- **DONE + LIVE:** Phase 0 (pipeline registry + freshness watchdog), Phase 3.1 categorisation (79%, platform-domain-aware), Phase 3.2 labour view (26.92%), Phase 3.3 costs summary (`mart.v_costs_summary_daily`, COGS provisional), invoice **date + line extractors** (pdfplumber → **gemma4-doc with think:false** — NOT qwen72b), **is-invoice gate** (classify_doc), **layout-learning loop**, crontab hygiene, NatWest schedule.
- **Metis note:** its "categorisation pilot (shadow)" overlaps Phase 3.1 — treat the LIVE `vendor_category_rules` + the categorise sweep as the baseline; don't re-derive. Hard file boundary already set by Metis vs invoice-filter files — keep it.
- **IN-FLIGHT:** line-item backfill (`logs/invoice-line-backfill-gemma.log`, gemma4-doc + gate + learning). Idempotent (skips invoices that have lines); if it dies, the **07:40 cron `u-invoice-line-sweep`** completes it. Safe to leave or stop.
- **Reversibility:** `public._backup_*` tables (categorise/platform/atr20/invoice-dates) — drop once verified.

## Prioritised execution order
1. **Phase 0** (registry + freshness) — keystone, additive, also the n8n-retirement evidence.
2. **Phase 3.1 categorisation** — biggest business value; GPU-free rules backfill; unblocks the costs summary.
3. **Phase 3.2/3.3** labour fix + costs summary — the owner's explicit deliverable.
4. **Phase 1** crontab hygiene (cheap, parallel).
5. **Phase 2** broken-feed fixes (u95, NatWest schedule, Dojo decision, line-flag).
6. **Phase 4** Hermes egress security.
7. **Phase 5** retire n8n — only when evidenced.

In flight tonight: invoice line-item backfill (qwen2.5:72b, ~660 invoices) + the date/line forward sweeps (cron). These belong in the registry (Phase 0).
