# home_ai — System Architecture (living document)

**Purpose:** the single end-to-end map of the home_ai system so we never again reconstruct it from scratch each session. Keep this updated whenever a pipeline/service/view is added or changes. Last full review: **2026-06-19** (4-agent deep review).

> The business: a pub (The Old Malthouse Inn, Tintagel), a cafe (Swirl), accommodation (rooms), and a property company. Entities: **1 = Atlantic Road Trading Ltd (work)**, 2 = Atlantic Road Estates Ltd, 3 = Personal, 4 = Family. Realms: **owner / work / personal** (`family` is a legacy alias for personal).

---

## 0. The single most important architectural fact

> ⚠️ **CORRECTED 2026-06-20 (measured from the live n8n execution log).** The earlier claim here —
> *"the n8n event path is largely DEAD"* — was **FALSE**. n8n is the live core. See
> [[n8n-decision-for-gpt55-review]] for the full measured state + the retirement decision brief.

**The system is a genuine HYBRID: (A) an n8n event bus handles the email/document/invoice flow, and
(B) ~66 cron "sweeps" pull every other source directly into the DB, bypassing the event bus.**

- **n8n is heavily load-bearing**, NOT dead. Measured runs/24h (2026-06-20): **Master Router 2,880** (≈every
  30s, 2,832 ok / 48 err — it claims queued events and dispatches them), **Gmail Ingest 323** (the real
  email→DB webhook path), **Invoice Pipeline P2 54** (active — *not* `active=false`), P5 EPoS / P6 Caterbook
  / P9 Report-Ingestion ~96 each, Telegram bot 1,440. **Alerting is 100% n8n**: Alertmanager →
  `http://homeai-n8n:5678/webhook/prom-alert`.
- Idle/not-firing n8n workflows: Bank CSV Import, Cleanup (weekly), Image Audit, **Partition Maintenance
  (0 runs — future monthly partitions at risk; July exists, check August)**.
- `events` today: 11,188 processed · **0 pending** · 1,146 **failed** (822 `document.received`, newest
  2026-06-04 — the V250 attachment-quarantine residue, now in *failed* not *pending*; 55 `email.received`
  failing today). **CORRECTED 2026-07-02:** the `ops.pipeline_runs` health registry is now live — 60+
  pipelines registered with heartbeat wrapping via `ops-run.sh` (the earlier "0 rows, never wired" claim
  is stale).

When adding **scraped/pulled** ingestion, default to a cron sweep. The **event bus itself is n8n-run** —
do not assume it's retired. Whether to migrate it off n8n is an open decision (see the brief above).

---

## 1. Financial data model (the truth model)

### Sales (revenue)
- **`touchoffice_department_sales`** — per-department revenue. Sites: `malthouse` / `sandwich` / `head_office`. **`head_office` is the consolidated truth** (per-till scrapes are contaminated: phantom ALCOHOL split, accom double-count). Departments: DRINK SALES, FOOD SALES, HOT DRINKS, Cafe Soft Drinks, Cafe Ice Cream, ACCOM, KITCHEN INT (always £0).
- **`touchoffice_fixed_totals`** — daily till totals (NET/GROSS sales, covers, cash/credit drawer) per site.
- **`v_daily_unit_economics`** — the daily revenue/labour spine. `total_revenue = COALESCE(head_office consolidated, per-till legacy)`; `revenue_source` flags which. Read by v_daily_cost_vs_sales + ~6 views; column order frozen.
- `epos_daily` — **EMPTY/DEAD** (revenue is 100% TouchOffice-sourced).

### Costs / purchases
- **`vendor_invoice_inbox`** (~16k rows) — the invoice store. `category_canonical` is a **GENERATED column** = `vendor_category_canonical(vendor_category)`; **NULL in → NULL out**.
- **`vendor_invoice_lines`** — line items (FK→inbox). Cols incl. `department` CHECK(**bar/kitchen/rooms/cafe/overhead**), qty, unit_price, line_net, category_hint, canonical_id.
- **`vendor_category_rules`** (~61 rows) — supplier `domain_pattern` → category. ⚠️ vocabulary is a mix of display-names + slugs.
- **`cogs_category_map`** (10 rows) — purchase-category → sales-department COGS bridge (a *third* taxonomy: `drink_alcohol`/`food`/...).
- Views: `v_daily_cost_vs_sales` (pivots cost off `category_canonical`), `v_gross_margin_period` (v_cogs_period × cogs_category_map vs dept sales), `v_invoice_categorised`.

### ⚠️ THE headline gap — invoice categorisation collapse
**~94% of 2026 invoices (and 98.6% all-time) have NULL `category_canonical`** (root cause: extractor leaves `vendor_category` NULL). So `v_daily_cost_vs_sales`'s per-category columns (net_wet/net_dry/net_cafe/net_repairs/net_utilities) read ~0 and everything lands in `net_other`. `net_cost_all` (sum of all) is still ~right; **any per-category COGS/GP/margin is broken until categorisation is backfilled.** There are **three incompatible category vocabularies** joined only by hand-maintained functions.

### Department taxonomy (purchases ↔ sales) — see [[feedback_department_taxonomy]]
Canonical: **bar, kitchen, rooms, cafe, overhead**. Synonyms: bar=drink sales(+hot drinks); kitchen=food=restaurant(+kitchen int); cafe=swirl=sandwich bar. Supplier→dept: St Austell→bar; J&R **TOM106=kitchen / MAL125=cafe** (delivery code, authoritative); Forest/Westcountry/Total Produce/Dole/Kingfisher/Bidfresh→kitchen; **Western Supply Co=repairs (overhead)**; Adam Moralee & Oana Stirban = Forest Produce staff (forestproduce.com)→kitchen; cafe utilities (phone/electric/water)→overhead.

### Labour (Tanda/Workforce, +26.92% on-cost)
- **`workforce_shifts`** (13k rows) — `award_cost` (base) → trigger sets `cost_estimate = award_cost × 1.2692` (on_cost_pct from static_context, anchored to May-2026 report).
- Views: `v_workforce_shifts_costed`, `v_daily_labour_by_team` (⚠️ **recomputes at 12.5% over staff_meta — inconsistent with the 26.92% basis**), `v_monthly_labour_vs_sales`.

### Bank — see [[project_bank_ledger_rebuild_2026_06_19]]
- **`bank_transactions`** (22,111 rows) — canonical ledger; `category` 100% populated. **`bank_accounts`** — account→entity/realm map. **`account_transfers`** — inter-account pair dedup. 2026 Dojo settlements arrive via **YouLend** (see [[feedback_dojo_youlend_financing]]).

---

## 2. Data ingestion pipelines

> See `docs/superpowers/plans/2026-07-02-r0-close-the-loop.md` (R0) for the current pipeline-health
> close-the-loop work (registry + heartbeat wrapping) referenced in the corrections below.

| Pipeline | Trigger | Target | Health |
|---|---|---|---|
| Gmail poll→events | n8n sched → google-fetch `/poll-and-emit` | `events` (email.received + document.received) | ✅ load-bearing |
| Email classify→invoice.detected | gmail-ingest webhook | emails, events | ✅ (downstream quarantined) |
| **Invoice harvester u95** | cron `50 6` | vendor_invoice_inbox | ✅ **HEALTHY** (corrected 2026-07-02 — earlier "503/container down" was stale) |
| **Invoice date sweep** (NEW) | cron `10 7` u-invoice-pdf-date-sweep | invoices.invoice_date | ✅ pdfplumber→gemma4-doc |
| **Invoice line sweep** (NEW) | cron `40 7` u-invoice-line-sweep | vendor_invoice_lines | ✅ pdfplumber→qwen2.5:72b, dept from J&R codes |
| PDF attach fetch u125 | cron `5 *` | data/invoice-pdfs + email_attachments | ✅ |
| Data-lane router u33 | cron `*/5` | natwest-inbox / dojo-inbox / vendor_invoice_inbox | ✅ feeder |
| NatWest CSV sweep | cron `25 7 * * *` u-natwest-inbox-sweep | bank_transactions | ✅ **scheduled** (corrected 2026-07-02 — earlier "unscheduled" was stale) |
| Bank balance-chain rebuild (NEW) | manual `--apply` | bank_transactions | ✅ remediation tool |
| Dojo sweep u135 | cron `15 7` | dojo_transactions | ⚠️ **STARVED** (no CSVs since ~06-15) |
| TouchOffice realtime/daily | cron `*/15`, `30 3`, `13 4` u274 | touchoffice_* | ✅ |
| Workforce/Tanda u29/u47 | cron `0 7`, `20 2` | workforce_* | ✅ |
| Caterbook u28/u286 + P6 | cron `30 7`, `37 5` | accommodation_bookings | ✅ (P6 was **dead 2026-06-14→2026-07-02**, repaired 2026-07-02 via three patches — now green) |
| Clover u78 | manual | clover_batches | ⚠️ manual-only |
| Cap-on-Tap / YouLend | — | — | ❌ not ingested (display-only) |

**Invoice extractor recipe (reuse this):** google-fetch `/message/{acct}/{mid}` → walk PDF attachment → `/attachment/{acct}/{mid}/{aid}` (`data_b64url`) → `homeai-pdfplumber:8003/extract-pdf` → local model (gemma4-doc date / qwen2.5:72b lines) → cross-foot/confidence-gate → DB. See [[feedback_invoice_date_from_pdf]].

---

## 3. AI / LLM stack

**Local models — AMD W7800 48GB (ROCm ollama `:11434`).** Tier→model in DB `static_context['model.tiers']`.
- **gemma4-doc** (18GB, multimodal, custom Modelfile temp 0 / num_ctx 32768) — invoice/doc vision + date extraction. ⚠️ **Gemma 4 is a *thinking* model — callers must send `think:false` or output is empty.**
- **gemma4-qat31b** — Hermes default + litellm. **qwen2.5:72b** (47GB) — heavy extraction (line items). **qwen2.5vl:72b/7b** — vision (7b = Hermes vision; 72b swaps with text on 48GB). **qwen2.5:7b** — hot tier (U7-optimised, 95.7% composite). **phi4:14b** — medium tier. **nomic-embed** — embeddings.
- **homeai-llm-router** (`:8001`) — tiered local→cloud picker; escalates low-confidence to claude-haiku-4-5; **cloud calls hard-fail through Presidio redaction**; **£6/day hard cap, fails closed**; logs to `ai_usage`.
- **homeai-litellm** (`:4000`) — `model=cap_*` → Anthropic, Presidio gate in one place.
- **homeai-pdfplumber** (`:8003`) — `/extract-pdf` + **`/render-page1-png`** (vision OCR rendering — enables the image-only-PDF branch). **homeai-markitdown** (`:8004`) — non-PDF→markdown.
- **Hermes** — daily-driver agent (Telegram), default gemma4-qat31b, delegation deepseek-v4-flash, `hermes_ro` SELECT-only role, MCP+SearXNG. ⚠️ **DeepSeek/GPT calls bypass Presidio + ai_usage logging** (open gap).
- **homeai-mcp** (`:8765`) — canonical external AI surface (Claude Desktop/Code/Hermes over Tailscale).

---

## 4. Infra, services, ops

- **34 containers**, 5 networks (`ai-internal`/`ai-services` are `internal:true` → must also attach `ai-monitoring`/`ai-proxy` to publish ports). Core: postgres:16, redis, **vault** (TLS-disabled, auto-unseal via age identity-file), **n8n** (`homeai_pipeline` role, UTC), **ollama** (ROCm), caddy (front door, binds tailnet IP), build-dashboard (`:8090`), frontend (Next.js, behind Authelia), playwright (scraping), bot-responder (cron exec target), critical-listener (Telegram <30s), paperless.
- **Auth/secrets:** Vault (`secret/postgres|gmail|anthropic|telegram|…`); **Authelia phase2 — NOT live** (tailnet is the real perimeter); RLS `entity_isolation`+`realm_isolation` on 10 tables, GUCs `app.current_entity`/`app.current_realm`; roles homeai_pipeline (RW), homeai_readonly (frontend/mcp), homeai_hr. ⚠️ several services still connect as **postgres superuser (BYPASSRLS)**.
- **Cron:** ~64 jobs in **JOLY's crontab** (not root's). ⚠️ multiple **duplicated/drifted lines** (breakfast, u163, weather-sync, u250).
- **Event bus:** `events` partitioned by month; `idempotency_key` non-unique → **INV-IDEMPOTENCY** (use `WHERE NOT EXISTS`, never `ON CONFLICT`). n8n runtime reads `workflow_history` for the active version (patching `workflow_entity.nodes` only updates the draft).
- **Safety:** `scripts/audit-invariants.py` (pre-push gate; INV-IDEMPOTENCY / ENTITY-GUC / PG-SUPERUSER / DOCKER-SOCK / PORTS / DB-ENTITY + new **INV-DB-COLLAPSE/DUP**). **DL-flood auto-pause** (dead_letter_count → Prometheus → n8n → `system.state=paused`, manual `/resume-all`). Backups: restic nightly (pw NOT in vault; root-owned files excluded → git-tracked). ⚠️ **alerting has a circular dependency on Vault** (sealed vault silences its own alert).
- **Gaming mode** — `scripts/gamemode.sh {pause|resume|status}` (alias `gamemode`, slash `/gamemode`). `pause` sets the kill switch `system.state=paused` (so `u241-supervisor` leaves Ollama down + won't page), settles in-flight work 15s, then stops `homeai-ollama` → **frees the whole GPU**. `homeai-ollama` is the *only* GPU-passthrough container (`/dev/kfd`+`/dev/dri`); all other AI services reach the card only via Ollama over HTTP, so this clears it entirely. `resume` restarts + warm-tests Ollama, unpauses, re-drives email events that queued/failed while paused, runs `selftest.sh` (aborts PAUSED if Ollama/model don't return). Manual-only by design (no cron).
- **Metis self-improvement loop** — `scripts/metis-nightly.sh` (06:45, shadow). OBSERVE→DETECT→PROPOSE→REVIEW→MEASURE beside each task; deterministic detectors, human-gated apply (`metis-apply.sh`), frozen `cognition.benchmark_labels`. Pilot: invoice categorisation. Tables in `cognition.*`. Spec: `docs/superpowers/specs/2026-06-20-metis-task-self-improvement-loop-design.md`. Reads invoice-pipeline outputs read-only; never edits those files.

---

## 5. Gaps & debt register (prioritised)

| # | Gap | Impact | Where |
|---|---|---|---|
| 1 | **94% invoices uncategorised** (`vendor_category` NULL) | breaks all per-category cost/COGS/GP/margin | §1 |
| 2 | **Three category vocabularies** (canonical slugs / rules display-names / cogs_category_map) | fragile hand-maintained joins | §1 |
| 3 | **u95 harvester broken** (503) | invoice capture stalled | §2 |
| 4 | **V250 quarantine** (document.received unclaimed; P2 inactive) | attachments never drain via events | §0 |
| 5 | **Labour basis inconsistency** (26.92% vs v_daily_labour_by_team 12.5%) | labour cost disagreement | §1 |
| 6 | **Dojo sweep starved** + **NatWest sweep unscheduled** + Clover manual + Cap-on-Tap/YouLend not ingested | stale/missing financial feeds | §2 |
| 7 | **Hermes DeepSeek/GPT egress** bypasses Presidio + cost logging | PII egress + cost blind spot | §3 |
| 8 | **gemma4 `think:false` requirement** | empty output if callers forget | §3 |
| 9 | superuser DB connections (BYPASSRLS); Authelia not live; alerting↔vault circular dep; duplicated crons; markitdown defined twice | security/ops debt | §4 |
| 10 | Line extractor silently drops J&R "0 lines" (not flagged) | silent data loss | §2 |

**The costs-summary the owner wants (rolling 7/30 GP by dept + overall, vs food/drink/labour/overhead spend) is blocked on gap #1** — fix categorisation (populate `vendor_category`/`category_canonical` from a supplier→category mapping) and `v_daily_cost_vs_sales` + the summary come alive.

---

## Keeping this live
- Update this doc in the same PR whenever a pipeline/service/view/cron is added or changed.
- Re-run the 4-domain deep review periodically (financial model / ingestion / AI stack / infra-ops).
- The high-level overview + this pointer live in memory `project_system_architecture` (loaded every session).
