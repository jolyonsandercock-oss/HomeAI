# Architecture Review — 2026-06

**Date:** 2026-06-14
**Lens:** context engineering (five context layers — user / session / enterprise / external / historical — plus handoff-confidence and cost-per-task), from `games/belt-dynasties/docs/CONTEXT_ENGINEERING_NOTES.md`.
**Method:** read-only fan-out over ingest pipelines, the AI/agent layer, the data/isolation core, and infra/ops; synthesised centrally.
**Spec:** `docs/superpowers/specs/2026-06-14-architecture-review-and-hermes-memory-bridge-design.md`

This is a living review. Findings distilled into pervasive memory live in
`[[project_architecture_review_2026_06]]` and `[[feedback_context_engineering_scorecard]]`.

---

## 1. System map

**34 containers across 5 Docker networks:**

| Network | Posture | Holds |
|---|---|---|
| `ai-internal` | `internal:true`, no egress | postgres, redis, the private bus |
| `ai-egress` | only network reaching the internet | n8n, ollama, llm-router, litellm, playwright, google-fetch, bot-responder, build-dashboard |
| `ai-monitoring` | publishable | prometheus, alertmanager, grafana, netdata, postgres-exporter |
| `ai-proxy` | publishable | caddy (TLS, Tailscale), authelia (SSO) |
| `ai-services` | — | vault, vault-agent, paperless, garmin |

**Core:** postgres 16 (single source of truth, ~610 tables, schemas public/raw/staging/mart/home_ai/cognition); redis; vault (29 secrets). **Local AI:** ollama (qwen2.5:7b, phi4, nomic-embed on the 3060), llm-router (tiered picker + spend ledger), litellm, presidio. **Surfaces:** homeai-mcp (`:8765`, canonical AI-readable), build-dashboard, homeai-frontend, metabase, open-webui, bot-responder, critical-listener.

---

## 2. Ingest pipelines — failure-mode table

The dominant risk class is **silent exit-0**: a shell/heredoc returns 0 while no data lands, so cron and watchdogs see success.

| Pipeline | Trigger | In → Out | Silent-failure mode | Guard / gap |
|---|---|---|---|---|
| invoice-pipeline | event `invoice.detected` → master-router | Gmail → `vendor_invoice_inbox`/`_lines` via extraction ladder | null-confidence row parks as `pdf_low_conf` and can loop forever; missing attachment → `no_pdf` | u284 PDF backfill, u281 vision drain — **but no alert on a permanently-stuck row** |
| report-ingestion (P9) | event `document.received` | attachment → `email_attachments` (sink) | idempotency no-op returns exit 0; CSV parser swallows parse errors | idempotency check — **no dead-letter on silent parse fail** |
| gmail-ingest | ~30s poll | Gmail → emails + signed events | empty poll exits 0 with null subject/from; HMAC event sigs **not verified downstream** | idempotency + u29 heartbeat — **consumers don't verify signatures** |
| nanny (P8) | event `child.event.detected` | email → `bot_instructions`/`child_school_note` | Haiku parse-fail → NULL → no row inserted | **export shows `active:false`** — see §7 debt #6 |
| touchoffice | cron 03:00 | Playwright scrape → `touchoffice_fixed_totals` etc. | GPU restart → `docker exec` exit 127 → whole day skipped, `overall_rc=0` → cron "success" | u54 watchdog — **bypassed because no timestamp row is written at all** |
| caterbook | cron 07:00 | Gmail arrivals → `caterbook_observations`/`_daily_snapshots` | same-day re-run: sanity check sees yesterday's *pre-existing* snapshot and passes incorrectly | retry + empty-check + sanity loop (the strongest of the seven) |
| weather | cron 07:30 | Open-Meteo → `weather_daily`/`_forecast` | API timeout → `{}` → KeyError, but **heredoc swallows the exit code** → exits 0, no rows, reports success | none for missing rows — weakest |

**Cross-cutting:** no pipeline writes an end-to-end "this day's ingest completed" marker (caterbook's sanity check is the nearest, and it has the re-run hole). A freshness/marker row per pipeline would convert every silent exit-0 into a detectable stall.

---

## 3. RLS / realm / entity — where context is set and lost

**Set:** frontend `withRealm()` wraps queries in a transaction and `set_config(...,is_local=true)`; migrations use session-scoped `set_config(...,false)`; n8n uses a **bare `SET app.current_entity` re-issued per statement** (the Postgres node breaks on `SET LOCAL`).

**Lost (all silent — a missing GUC yields 0 rows under the PERMISSIVE policy, not an error):**

1. `SET ROLE` drops the role's GUC defaults → `app.current_entity` empty → 0 rows. (V177 per-role defaults drafted, not applied.)
2. n8n pooled connections: GUC re-set is **convention, not enforced** — a borrowed connection without the re-set leaks or zeroes.
3. Frontend `set_realm` outside a transaction → LOCAL scope auto-commits away → cross-realm leak (the U147 bug).
4. Trigger ordering: entity-derivation must fire before realm-derivation (V260 enforces alphabetically).
5. CASE eager-cast (`='all'` vs `::int`) — fixed in V5; a regression would error on every read.

**Evidence of impact:** V260/V266 found ~11,120 silently NULL-entity rows accumulated in `bank_transactions`. **Enforcement:** `scripts/audit-invariants.py` (9 invariants, FAIL/WARN, `--check` pre-push gate, live-DB checks for the NULL-entity defect).

---

## 4. Context-engineering scorecard

Each AI component scored against the five context layers, plus whether handoffs carry confidence/reasoning and whether per-call cost is tracked. `~` = partial.

| Component | Model | User | Session | Enterprise | External | Historical | Handoff carries confidence | Cost tracked | Named gap |
|---|---|---|---|---|---|---|---|---|---|
| **Hermes** | deepseek-v4-flash (+haiku escalation) | ✓ | ✓ | ✗ | ✓ | ✓ | ✗ (bare proposals) | **✗** | No business rules; cost unlogged |
| **bot-responder** | haiku-4.5 (+sonnet) | ✓ | ✓ | ✓ | ✗ | ✗ | ~ (logs reason, not fed back) | ✓ | No sender-history feedback loop |
| **homeai-mcp** | — (data server) | ✓ | n/a | ✓ | n/a | ✓ | n/a | n/a | — |
| **llm-router** | tiered local→cloud | ✗ (task_type only) | ✓ | ✓ | ✓ | ✓ | ~ (escalation_reason opaque to caller) | ✓ | Realm-blind |
| **invoice-extract** | qwen→haiku→sonnet ladder | ✓ | ✓ | ~ | ✓ | ✓ | ~ (numeric threshold only) | ✓ | **realm/entity hardcoded owner/1 — no personal/property** |
| **report-parser** | haiku→sonnet | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ (reasoning string, unused) | ✓ | Reasoning produced then discarded |
| **counterparty-resolver** | rule-based | ✗ | ✓ | ✗ | ✓ | ✗ | ~ (confidence + source) | ✗ | No learning from human review |

---

## 5. Context-engineering blind spots (the cross-component pattern)

1. **Enterprise rules are hardcoded, not queryable.** Tier thresholds, prices, KPI bands (V223) live in code; agents can't see policy as context.
2. **No user-history feedback loop.** `query_rejections` and per-sender accuracy exist but never feed back into escalation decisions.
3. **Confidence/reasoning is produced but not propagated.** report-parser emits reasoning that's discarded; the ladder escalates on a bare number; human review gets no "why".
4. **Cost visibility is uneven.** llm-router/bot/ladder log to `ai_usage`; **Hermes logs nothing** — a growing blind spot as Hermes becomes the daily driver.
5. **Realm context stops at the data layer.** llm-router is realm-blind; invoice-extract hardcodes `owner`/entity 1, so personal/property invoices aren't isolated.

---

## 6. Vault fragility map

Vault is an accepted single point of failure: sealed, **~80% of async pipelines freeze** (n8n and all 22 workflows, google-fetch, llm-router cloud escalation, playwright scrapers, bot-responder, build-dashboard API). **Survives:** postgres, redis, ollama (local inference), prometheus/grafana, caddy, paperless OCR. **Mitigations:** age-identity auto-unseal; a host-level `vault-watchdog` systemd timer (layer 3, Vault-independent) that pages Telegram on seal-state change — this is what saves alerting, since the in-Docker notify-bridge is itself Vault-dependent.

---

## 7. Ranked architectural debt

| # | Debt | Blast radius | Fix sketch |
|---|---|---|---|
| 1 | **Silent exit-0 ingest** (weather heredoc swallows exit code; touchoffice GPU exit-127 skips the day at `rc=0`) | A missing day looks like success; watchdogs blind | Each pipeline writes a `pipeline_run(date, rows)` marker row; a freshness check alerts on a missing/zero-row marker |
| 2 | **Enterprise context hardcoded** (thresholds, prices, realm/entity in invoice-extract) | Agents can't see policy; invoice-extract can't handle personal/property | Expose KPI/policy as an MCP resource; parameterise realm/entity off `entity_id` |
| 3 | **n8n GUC re-set is convention, not enforced** | Silent 0-row isolation bugs (~11,120 NULL-entity rows already accrued) | Apply V177 per-role GUC defaults; tighten INV-ENTITY-GUC to FAIL on any bare write |
| 4 | **No confidence/reasoning handoff envelope** | Human review lacks "why escalated"; next tier re-reasons cold | Standard handoff struct (result + confidence + reasoning + open-questions) across AI steps |
| 5 | **Hermes cost unlogged** | Budget ledger blind to the daily driver | Log Hermes calls to `ai_usage` (provider='hermes', task_type derived) |
| 6 | **Pipeline export/live drift** (n8n export shows P2 invoice + P8 nanny `active:false`, but P2 went live U243 2026-06-06) | Reviews mislead; real status unknown from the repo | Reconcile `.claude/n8n-exports/*` against live `activeVersionId`; treat live DB as truth |
| 7 | **HMAC event signatures not verified downstream** | A Vault compromise could inject unsigned events undetected | Verify signatures in P2/P8/P9 consumers, not just at emission |

> **Note on #6 (session-entry discipline):** the `active:false` reading comes from a possibly-stale export. Per `[[project_invoice_pipeline_p2_live]]`, P2 was fixed and drained live on 2026-06-06 (U243). The debt is the *drift between export and live state*, not a confirmed dead pipeline — verify against live before acting.
