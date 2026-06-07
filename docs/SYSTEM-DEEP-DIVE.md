# Home AI — System Deep-Dive

*An honest, ground-up description of everything that runs, why it's built the way it
is, how it stays secure, how it checks itself, and how it remembers. Written
2026-06-07 from the live system (numbers are real, pulled the day of writing).*

---

## 0. What this actually is

This is a private, self-hosted "administrative brain" for **Jo's three businesses**:
a **pub** (The Olde Malthouse Inn, Tintagel), a **property company** (several
residential lets + mortgages), and **personal/family** affairs. It ingests the
paperwork and data those businesses generate — bank feeds, invoices, emails, EPOS
sales, hotel bookings, utility bills, council/compliance documents — reconciles and
files it, answers questions about it, and flags what needs attention.

It runs on **one machine in the house** (a Lenovo P620 workstation). Nothing here is
a SaaS product; it's a personal system built incrementally over ~250 "sprints"
(the `Vxxx` migration numbers and `Uxx` sprint tags are the archaeology). The design
priorities, in order: **don't lose or corrupt financial data → keep working
unattended → be cheap to run → be private**. Most decisions below fall out of those.

---

## 1. The host & physical layout

- **Machine:** Lenovo P620, Ubuntu (Linux 7.0 kernel), **107 GB RAM**, **NVIDIA RTX
  3060 (12 GB VRAM)**. One consumer GPU is the single biggest constraint on the AI
  design — it's why the local models are 7–14B, not 70B (see §5).
- **Disks:** a **915 GB NVMe** (system + all live data, currently **36 % used** after
  a cleanup) and a **5.5 TB spinning HDD** (`/mnt/shared_storage`, almost empty,
  used for scan-inbox and earmarked for cold/bulk data). Speed-critical data
  (Postgres, Vault, the event bus) stays on NVMe by policy.
- **Reachability:** the house machine is exposed to Jo's other devices over
  **Tailscale** (`jolybox.tailc27dff.ts.net`), never the public internet directly.
- **Everything is Docker Compose.** `docker-compose.yml` is the single source of
  truth for what runs. **34 containers** today, on **5 user-defined networks** that
  enforce isolation:
  - `ai-internal` — the private bus; marked `internal: true` so containers on it
    **cannot reach the internet** (a deliberate egress firewall).
  - `ai-egress` — the only network with outbound internet, attached just to the few
    services that genuinely need it (the LLM gateway → Anthropic, news fetch).
  - `ai-monitoring`, `ai-proxy`, `ai-services` — segmentation for Prometheus/Grafana,
    the reverse proxy, and shared services.
  - *Gotcha baked into memory:* because `ai-internal` is `internal:true`, publishing a
    host port from a container attached **only** to it silently fails — services that
    need a host port are also attached to a non-internal network.

### The 34 containers, grouped by what they do
- **Data & state:** `postgres` (the brain), `redis` (queues/cache), `qdrant` (vector
  store), `vault` + `vault-agent` (secrets).
- **AI inference & routing:** `ollama` (local GPU models), `llm-router` (the tiered
  model picker + spend ledger), `litellm` (OpenAI-compatible proxy), `model-evaluator`
  (benchmark harness), `presidio` (PII redaction before anything leaves the house).
- **Ingestion & document handling:** `n8n` (workflow engine), `google-fetch` (Gmail
  send/receive), `paperless` (document OCR/archive), `pdfplumber` + `markitdown`
  (PDF→text/markdown), `playwright` (headless-browser scrapers).
- **Interfaces:** `build-dashboard` (the main FastAPI app + "Mission Control" UI),
  `frontend` (a Next.js app), `open-webui` (chat UI), `bot-responder` (the
  Telegram/email Q&A bot), `wa-bridge` (WhatsApp), `mcp` (the AI-tool surface),
  `metabase` (BI), `searxng` (private search), `data-proxy` (token-gated external read).
- **Security & edge:** `caddy` (reverse proxy + TLS), `authelia` (SSO/login).
- **Observability:** `prometheus`, `grafana`, `alertmanager`, `blackbox-exporter`,
  `postgres-exporter`, `netdata`, `critical-listener`.

---

## 2. The data layer — Postgres is the spine

Almost everything is in **one PostgreSQL instance**. That's deliberate: a single
transactional store with strong constraints is the cheapest way to keep financial
data honest. n8n, the dashboard, the bot, and the AI all read/write the same DB.

- **6 schemas, 610 tables total** (254 in `public`):
  - `public` — the live application tables (bank, invoices, emails, events, …).
  - `raw` / `staging` / `mart` — a **classic ELT pipeline**: raw scraped/imported
    data lands in `raw`/`staging`, gets cleaned and reconciled, and the trustworthy
    aggregates live in `mart` (e.g. `mart.daily_totals`, `mart.exceptions`,
    `mart.cash_variance` — what the reconciliation dashboard reads).
  - `home_ai` — **functions & introspection** (the realm helpers, the SQL-dependency
    graph, the n8n registry — see §6). Not business data.
  - `cognition` — **the system watching itself** (benchmarks, which AI "schemas"
    fire, bot routing decisions).
- **251 migrations** (`postgres/migrations/Vxxx__*.sql`, latest **V247**). Every
  schema change is a numbered, reviewed, reversible migration applied with
  `ON_ERROR_STOP`. CI enforces the sequence is contiguous (gaps must be allowlisted).
- **114 public views + 10 `home_ai` views.** Views are used heavily so the AI and the
  dashboard query stable, named shapes instead of raw tables.

### What the data actually looks like (live counts, day of writing)
| Domain | Table | Rows | Notes |
|---|---|---|---|
| Banking | `bank_transactions` | **22,476** | 5 accounts; **de-dup is mandatory** (many exact-dup rows — see §9) |
| Credit cards | `card_statements` | 71 | 4 RBS Mastercards, paired transfers |
| Invoices | `vendor_invoice_inbox` | **15,946** | captured + categorised; the AI-extraction target |
| Email | `emails` | **75,171** | full-text searchable (GIN/`tsvector`) |
| Event bus | `events` (+ monthly partitions) | 8,833 live | the async backbone (see §4) |
| Audit | `audit_log` | **48,847** | who/what/when for pipeline + AI actions |
| AI ledger | `ai_usage` | 3,174 | every model call: tokens, £cost, tier, realm |
| Hospitality | `caterbook_room_nights` | 654 | hotel bookings → accommodation revenue |
| Documents | `documents` | 41 | Paperless-linked scans (mortgages, compliance) |
| Bot | `bot_instructions` | 207 | inbound instructions from Jo |
| AI query surface | `query_whitelist` | 213 (211 active) | the "slugs" the AI is allowed to run (see §6) |
| Ops | `system_alerts` / `dead_letter` | 182 / 1,268 | alerts + failed-event graveyard |

---

## 3. The security model — realms, RLS, secrets, redaction

Security here is **defense in depth at the data layer**, because the threat model is
"an AI or a workflow does something dumb with financial/personal data," not a remote
attacker. The layers:

### 3.1 Realms (the core idea)
Every sensitive row carries a **`realm`**: `owner`, `work`, `personal`, or `shared`.
- `work` = pub + property business; `personal` = family/personal; `owner` = Jo's
  god-view that sees everything; `shared` = visible to both work and personal.
- This was a 3-realm split (V164/V164b, 2026-05-19) — the design rule is now
  **"every table, route, and identity must declare its realm"** — it's not optional.

### 3.2 Row-Level Security (RLS) — the enforcement
- **117 of 254 public tables have RLS on, with 167 policies.** Two policy types:
  - `realm_isolation` (**RESTRICTIVE**): owner sees all; work sees work+shared;
    personal sees personal+shared. Driven by the GUC `app.current_realm`.
  - `entity_isolation` (**PERMISSIVE**): filters by `app.current_entity` (which
    business). `'all'` sees everything; a numeric id scopes to one entity.
- **The subtle, important part:** RLS only bites a **non-superuser** role. For years
  most services connected as the `postgres` superuser, which *bypasses RLS entirely* —
  so RLS was "armed but not firing" for them. The realm columns were used for
  explicit filtering, but the kernel-level guarantee wasn't on.

### 3.3 Database roles & the H5 rollout (this is recent and matters)
8 custom roles exist (`owner_role`, `trading_role`, `personal_role`,
`homeai_pipeline`, `homeai_readonly`, `homeai_hr`, plus `metabase_app`, `paperless`).
The **realm helper** `home_ai.set_realm()` enforces role↔realm pairing (e.g.
`trading_role` can only set realm=`work`).
- **n8n** already connects as `homeai_pipeline` (non-super) with the GUCs set — so RLS
  has genuinely been enforcing for the busiest writer all along.
- **bot-responder** runs the *risky* path (executing AI-generated SQL) as
  `homeai_readonly` (non-super, read-only transaction, realm set from the caller) —
  so the AI literally cannot read across realms or write.
- **build-dashboard** historically connected as superuser. The **H5 rollout (today)**
  flipped `RLS_ENFORCE_SET_ROLE=1`: its shared DB helpers now `SET LOCAL ROLE
  homeai_pipeline` per transaction, so RLS actually enforces on those code paths.
  - *The landmine that made this hard:* `SET ROLE` does **not** inherit the role's
    `ALTER ROLE SET` GUC defaults, and `entity_isolation` is permissive — so without
    explicitly setting `app.current_entity`, every query silently returns **zero
    rows**. The fix sets both GUCs every time. (`SET LOCAL ROLE` is transaction-scoped
    so pooled connections never leak the de-privileged role — verified: idle
    connections show `is_superuser=on`.)
  - **Honest status:** this is enforced on the *helper* paths; ~50 older "inline"
    dashboard endpoints still use a superuser connection (no breakage, just not yet
    enforced) and are being migrated opportunistically. It's partial, by design.

### 3.4 Secrets — Vault
- **HashiCorp Vault** (currently **unsealed**, **29 secrets**) holds every credential:
  DB passwords, the Anthropic API key, Gmail OAuth, scraper logins, Telegram tokens.
- Auto-unseal is hardened with an age identity file; a **host-level watchdog**
  (in root's systemd, outside Docker) pages Telegram if Vault's seal state changes —
  because Vault sealing takes ~80 % of the pipelines down, and the alerting itself
  depends on Vault (a circular dependency that bit hard once and is now mitigated).
- **Discipline:** secrets are **never** written to files or git. A pre-commit entropy
  scan + a CI entropy job + a filename hook block `*secret*`, `*.env`, private keys,
  `hvs.` Vault tokens, and high-entropy hex blobs. (A new rule this session: any
  `sudo` command >20 chars is delivered as a *script*, because the terminal wraps long
  pasted commands and orphans secret args.)

### 3.5 The edge & identity
- **Caddy** terminates TLS and reverse-proxies. **Authelia** (3 users: Jo + a manager
  + a general staff account) provides SSO; `/app`, `/dashboard`, `/grafana` sit behind
  `forward_auth`. Public surfaces (the guest breakfast form, health checks) are
  explicitly allow-listed.
- **Two Google identity paths, deliberately not unified:** consumer Gmails on OAuth;
  Workspace identities on domain-wide delegation via a service account.

### 3.6 PII never leaves un-redacted
Before any prompt goes to a cloud model (Anthropic), it passes through **Presidio**
redaction (names, account numbers, etc.). Local models (on the GPU, in the house) get
the raw text; only cloud escalation is redacted. The egress firewall (§1) backs this
up — only the gateway can reach the internet.

---

## 4. The automation layer — events, workflows, pipelines

The system is **event-driven**. Things happen asynchronously and durably.

- **The event bus** is the `events` table (monthly-partitioned for volume). Producers
  insert events (`email.received`, `document.received`, …); consumers process them;
  failures land in `dead_letter` (1,268 historical; recent = 0). Idempotency keys and
  processing leases prevent double-work and stuck jobs.
- **n8n** is the orchestrator — **22 active workflows**, stored *in the same Postgres*
  (`workflow_entity`). The major pipelines:
  - **Gmail Ingest Pipeline** (26 nodes) — polls Gmail, classifies, emits events.
  - **Master Router** (12 nodes) — the hub that fans out to email-pipeline,
    invoice-pipeline, report-ingestion, nanny.
  - **Report Ingestion (P9)**, **Nanny (P8)**, **Bank CSV Import**, **Caterbook
    Bookings (P6b)** (hotel), **Pub Anomaly Alerter**, **Cornwall News Briefing**,
    **Image Audit**, **Alertmanager Sink**, **Watchdog — n8n Errors**, **Telegram Bot**.
- **Invoice extraction** is the heaviest AI consumer — a scraper/email drops a PDF,
  pdfplumber/markitdown extract text, and the **ladder** (§5) extracts structured
  fields, escalating from the free local model to cloud only when unsure.
- *n8n gotchas that are now institutional knowledge:* the runtime reads
  `workflow_history` via `activeVersionId` (editing `workflow_entity.nodes` alone does
  nothing); a literal `}}` inside an `{{…}}` expression breaks its naive parser;
  multi-trigger workflows break cron; a "skip — already done" node returning no item
  caused dead-letter floods that auto-paused pipelines (now patched).

---

## 5. The AI layer — tiered, cheap, mostly local

The governing idea: **do as much as possible on the free local GPU; escalate to paid
cloud only when confidence is low.** This is both a cost and a privacy decision.

### 5.1 The model ladder
- **Local (Ollama, on the RTX 3060):** `qwen2.5:7b` (the workhorse — prompt-engineered
  to ~95.7 % composite accuracy on the invoice eval), `qwen3.5:9b`, `phi4:14b`,
  `nomic-embed-text` (embeddings). The 12 GB VRAM ceiling is why nothing bigger runs.
- **Cloud (Anthropic):** Haiku 4.5 for medium escalation, Sonnet 4.6 for the hardest.
- **The invoice ladder** (`ladder.py`): try `qwen2.5:7b`; accept if confidence ≥ **0.70**
  (lowered from 0.75 today to keep more on the free model); else Haiku (≥0.55); else
  Sonnet (≥0.50). **Today: 2,154 local calls cost £0.00; 560 Haiku = £2.22; 27 Sonnet
  = £0.71** over 7 days. The local model does the overwhelming majority for free.
- `llm-router` is the gateway: picks the tier, redacts via Presidio, calls the model,
  and **writes every call to `ai_usage`** (tokens, £cost, latency, model, tier, realm,
  cache hits). `litellm` gives an OpenAI-compatible surface for tools that want it.

### 5.2 The budget system — and an honest caveat
- A **£3/day API cap** is split into priority tiers, enforced as a *floor* model:
  **P0 30 % (£0.90)** — financial recon, invoices, compliance (a guaranteed floor that
  can't be cannibalised); **P1 35 % (£1.05)** — email/triage; **P2 21 % (£0.63)** —
  RAG/lookups; **P3 14 % (£0.42)** — news/exploratory. Each `ai_usage` row is tagged
  to a tier by a DB trigger.
- **Honest caveat: this is "shadow mode."** The tables carry `enforce_mode=t`, but the
  gateway does **not** actually return 429s — it logs what it *would* block. So the
  budget is *observed*, not *enforced*. (When Jo runs heavy build/import work on the
  Claude Max subscription, that overrules the metered API budget anyway.) The alerting
  around this was de-noised today: P0 is a floor, so "P0 over £0.90" is expected on a
  busy invoice day and no longer pages; the real signal is now total spend nearing £3.

### 5.3 The Q&A bot
`bot-responder` answers questions over Telegram/email. It does **not** let the AI write
arbitrary SQL — the AI may only run **whitelisted slugs** (§6) or read-only queries as
`homeai_readonly`. Inbound trust is narrow: only Jo, only from his Telegram and one
email address. Outbound only from one bot mailbox.

---

## 6. How the system remembers and knows things

There are **several distinct knowledge systems**, each for a different consumer. This
is probably the most interesting part of the architecture.

### 6.1 `query_whitelist` "slugs" — the AI's safe query surface
**213 slugs** (211 active), realm-scoped (owner 60, shared 94, work 59). A slug is a
named, parameterised, pre-approved SQL template (`:named` params). The bot/AI can only
run these — it can't invent SQL against the raw tables. A **validation trigger** (V238)
`EXPLAIN`s every slug at write time and rejects any that don't plan, so a slug
referencing a dropped column can't even be saved. This is the curated "what questions
can be asked" index.

### 6.2 The SQL dependency graph (`home_ai.v_view_deps`, `v_object_edges`, …)
Built this session. It flattens Postgres's own dependency catalog (`pg_depend`,
`pg_rewrite`, `pg_policy`, `pg_trigger`) into queryable views + recursive functions, so
"what depends on `vendor_invoice_inbox`?" or "which views read column
`category_canonical`?" is one query instead of reading view definitions by hand. Answers
the "why is this number wrong?" class of question. Exposed over MCP.

### 6.3 The n8n workflow registry (`home_ai.v_n8n_*`)
Also built this session. Extracts, from n8n's own tables, which workflow calls which
service (HTTP node URLs), reads/writes which DB tables (regex over the postgres-node
SQL, filtered to real tables), and which workflow triggers which (matching httpRequest
`/webhook/<path>` to webhook nodes). So tracing an event chain across 22 workflows is a
query, not a read of 22 JSON blobs. **It bridges into the SQL graph** — "this workflow
writes table X → which feeds these 5 views."

### 6.4 The MCP server — the canonical AI-readable surface
`homeai-mcp` (FastMCP) is the standard way external AI talks to the system: tools like
`run_slug`, `query_postgres_readonly`, `sql_lineage`, `n8n_workflow`, plus resources
like `homeai://today`. The rule is "new AI-readable data goes through MCP slugs/
resources, not bespoke REST endpoints."

### 6.5 `cognition` schema — the system observing itself
`schema_fires` (**2,365 rows**) logs which AI "schemas" actually fire (to prune ones
that never do); `bot_routing_decisions` records how the bot classified each question;
`benchmark` holds model-eval results. This is the feedback loop for tuning the AI.

### 6.6 Vector memory
`qdrant` is deployed for semantic/RAG search (and `nomic-embed-text` produces the
embeddings), though it's lightly used — flagged as a keep-or-kill decision.

### 6.7 The agent's own memory (this assistant)
Separately from the system, the AI assistant that *builds* this (me) keeps a
**file-based memory** at `~/.claude/.../memory/` — **67 fact files** plus a `MEMORY.md`
index loaded every session. Each file is one fact with frontmatter and a type
(`user` / `feedback` / `project` / `reference`). This is how hard-won lessons (§9) and
project state survive between sessions. It's deliberately separate from the system's
own data — it's *meta-knowledge about building the system*.

### 6.8 `SPEC.md` (7,000+ lines) and `AGENTS.md`
Long prose+SQL design docs. Useful but drift-prone; the rule is "live system wins over
docs" and state is reconciled at session start.

---

## 7. Modes & flags — the system has dials

- **`REALM_ENFORCE=1`** — the dashboard reads the user's realm (from Authelia groups /
  an `X-Realm` header) and pins `app.current_realm` per request.
- **`RLS_ENFORCE_SET_ROLE=1`** — (new, today) helper DB paths drop superuser so RLS
  enforces. Instant rollback: set to 0 + recreate.
- **Quota `enforce_mode`** — *flagged on but shadow in practice* (§5.2).
- **Feature flags generally** — risky changes ship behind a flag defaulting to the old
  behaviour, get canary-tested in the live system, then flip. This is the standard
  pattern for anything with blast radius.

---

## 8. How the system checks itself

Multiple independent guardrails, because the system runs unattended:

- **`selftest.sh`** — the deep verification harness. **52 checks, currently 52/0/0
  PASS:** every container running, Vault unsealed, the RLS test suite, 22 active
  workflows present, all HTTP probes 200, all Prometheus metrics exposed, nightly
  backup <24h old + restic snapshots present, data fixtures, and (new today) a check
  that **every static SQL query in the dashboard still plans against the live schema**
  — the permanent guard against the "stale column" bug class (§9).
- **CI (GitHub Actions)** — lints shell+Python syntax, an entropy scan, and a
  migration-contiguity check. No live DB (runs on free runners); the DB-dependent
  tests are the bash scripts above.
- **In-database triggers** — `validate_slug` (rejects unplannable slugs),
  `ai_usage_autopopulate` (stamps tier/capability), RLS policies (deny-by-default).
- **Watchdogs** — a host-level Vault watchdog (systemd, outside Docker), a cron-health
  watchdog (`*/30`, raises self-resolving `CronStale` alerts), an n8n-errors watchdog,
  GPU-recovery (CDI spec drift → exit 127), backup-freshness.
- **Monitoring** — Prometheus scrapes custom DB metrics (event overflow, dead-letter
  count, lease age, HMAC verification, …) + node/GPU; Alertmanager → a notify bridge →
  Telegram. Alerts are kept *actionable* (heartbeat/quota noise was deliberately
  silenced — a quiet channel is a channel people read).

---

## 9. The tricks & the scar tissue (hard-won gotchas)

These are the landmines that have actually bitten, now encoded as memory so they don't
again. They're worth knowing because they explain a lot of the defensive code:

- **Bank rows duplicate.** `bank_transactions` has many exact-dup rows; **every**
  financial `sum()` must de-dup first (row_number partition). The ATR reconciliation
  error post-mortem produced 7 mandatory recon rules (compute-and-assert totals,
  DB-derive every line, unique symmetric join keys, statement-anchored dates,
  dedup/canonical-source, an entity is not one account, always cross-foot).
- **`SET ROLE` drops GUC defaults** → permissive `entity_isolation` fails closed →
  silent zero rows (§3.3). The H5 fix exists because of this.
- **Postgres doesn't short-circuit `OR`** in RLS — `setting='all' OR id=setting::int`
  errors when `setting='all'`; needs a CASE/regex guard before any cast.
- **STORED generated columns read NULL in BEFORE triggers** if the source column isn't
  in the UPDATE SET — cost 106 pub rows once before it was caught.
- **Docker bind-mount inode trap** — atomic-replace editors (and moving a host dir)
  break a running container's bind mount silently; it keeps reading the old inode until
  restart. This is why moving live-mounted dirs (the restic backup repo, the storage
  write-path) is done by container-recreate, never a naive symlink.
- **n8n `}}` parser trap; `$N` bind-var collision** (pg-promise reads `$N` as binds, so
  inline values starting with a digit break) — both shaped how workflow SQL is written.
- **Botched bulk-edit corruption** — three+ times a scripted edit landed lines in the
  wrong place (12 corrupted route files; an invoice script; a bot-audit INSERT against
  non-existent columns). Found and fixed this session; the new `selftest` SQL check +
  the slug `EXPLAIN` trigger are the permanent defense.
- **The terminal wraps long pasted `sudo`/`!` commands**, orphaning trailing args — so
  long privileged commands are always delivered as scripts now.

---

## 10. What's been achieved — and an honest assessment

### Solid and working
- A single, constrained, **heavily-audited financial datastore** (22k bank lines, 16k
  invoices, 48k audit rows) with a real ELT pipeline (raw→staging→mart).
- **Mostly-free AI extraction** — the local GPU does the bulk; cloud spend is ~£0.40/day.
- **Realm + RLS isolation** genuinely enforcing for the highest-risk paths (n8n, the
  bot's AI-SQL, and now the dashboard helper paths).
- **Self-verifying** — 52/52 selftest, a green CI, watchdogs, and now a guardrail that
  catches the recurring "stale schema" bug class automatically.
- **Recoverable** — Vault auto-unseal hardened after two seal incidents; restic backups
  (11 snapshots, nightly, <24h fresh); code mirrored to an off-host GitHub backup with a
  mandatory entropy scan before every push.
- **Self-describing** — the SQL graph + n8n registry + slugs + MCP mean the system can
  now *explain its own structure* to an AI.

### Fragile / partial / deferred (the honest list)
- **Quota enforcement is shadow-only** — nothing actually blocks overspend; it relies
  on the £3 ceiling being soft and Max overruling during builds.
- **RLS rollout is partial** — ~50 inline dashboard endpoints still run as superuser
  (not enforced; not broken). Opportunistic migration.
- **Backups are local-first** — restic is on the same NVMe; the off-host copy is *code*,
  not the *data*. A true off-host data backup (the NAS path is referenced but the live
  off-host destination is the gap) is the most important resilience hole.
- **Single points of failure** — one machine, one GPU, one Postgres, one unmirrored
  HDD. Fine for a personal system; worth naming.
- **Dead-letter backlog** (1,268 historical) and a once-6,500-row invoice backlog show
  the ingestion can over-fire; guards were added but the noise is real.
- **Some integrations are degraded** — Trail (needs a Playwright rewrite), Dojo (manual
  CSV), Xero (API-blocked), Qdrant (barely used).
- **Doc drift** — SPEC.md/AGENTS.md lag reality; the live system is the source of truth.

### The shape of it, in one breath
A privacy-first, single-box, event-driven, Postgres-centred administrative engine that
ingests a small-business's paperwork, extracts it cheaply with a local-first AI ladder,
keeps it honest with realm/RLS isolation and obsessive auditing, watches and tests
itself, and — increasingly — can describe its own internals well enough to be safely
operated by an AI. It is not bullet-proof (shadow quotas, partial RLS, local backups),
but the failure modes are known, named, and mostly guarded.
