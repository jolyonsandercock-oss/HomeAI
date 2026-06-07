# A Self-Hosted "Administrative Brain" — System Deep-Dive (anonymised)

*An honest, ground-up description of a privately-built, self-hosted automation system:
the tech, the design decisions, how it stays secure, how it checks itself, and how it
remembers. Anonymised for sharing — identifying names, locations, hostnames, and
third-party vendors have been removed; the architecture and numbers are real.*

---

## 0. What this actually is

This is a private, self-hosted **administrative engine** for a small-business owner who
runs a few distinct concerns: **a hospitality venue (a pub with rooms), a small
property-letting company, and personal/family affairs**. It ingests the paperwork and
data those generate — bank feeds, invoices, emails, point-of-sale sales, room bookings,
utility bills, compliance documents — reconciles and files it, answers questions about
it, and flags what needs attention.

It runs on **one machine in the owner's home**. Nothing here is a SaaS product; it's a
personal system built incrementally over ~250 small "sprints." The design priorities,
in order: **don't lose or corrupt financial data → keep working unattended → be cheap
to run → be private**. Most decisions below fall out of those.

---

## 1. The host & physical layout

- **Machine:** a single workstation — ~107 GB RAM, **one consumer GPU (12 GB VRAM)**.
  That single GPU is the biggest constraint on the AI design: it's why the local models
  are 7–14B parameters, not 70B.
- **Disks:** a ~1 TB NVMe (system + all live data, ~36 % used after a cleanup) and a
  large spinning HDD (mostly empty, earmarked for cold/bulk data). Speed-critical data
  (the database, the secrets store, the event bus) stays on NVMe by policy.
- **Reachability:** the machine is reachable from the owner's other devices over a
  private mesh VPN, never the public internet directly.
- **Everything is Docker Compose.** One compose file is the single source of truth for
  what runs — **34 containers** today, on **5 user-defined networks** that enforce
  isolation:
  - an **internal** network marked `internal: true` so containers on it **cannot reach
    the internet** (a deliberate egress firewall);
  - an **egress** network — the only one with outbound internet, attached just to the
    few services that genuinely need it (the LLM gateway, news fetch);
  - separate networks for monitoring, the reverse proxy, and shared services.
  - *Gotcha:* because the internal network is `internal:true`, publishing a host port
    from a container attached **only** to it silently fails — services needing a host
    port are also attached to a non-internal network.

### The 34 containers, grouped by job
- **Data & state:** PostgreSQL (the brain), Redis (queues/cache), a vector DB, a
  secrets vault (+ its agent).
- **AI inference & routing:** a local-model server (GPU), an LLM **router** (tiered
  model picker + spend ledger), an OpenAI-compatible proxy, a benchmark harness, and a
  **PII-redaction** service (scrubs personal data before anything leaves the house).
- **Ingestion & documents:** a workflow engine, a mail send/receive bridge, a
  document-OCR/archive service, PDF→text/markdown extractors, a headless-browser
  scraper.
- **Interfaces:** the main app + dashboard (FastAPI), a web frontend, a chat UI, a Q&A
  bot (chat/email), a messaging bridge, an **MCP** server (the AI-tool surface), a BI
  tool, a private search engine, a token-gated external-read proxy.
- **Security & edge:** a reverse proxy (TLS), an SSO/login gateway.
- **Observability:** Prometheus, Grafana, Alertmanager, blackbox + DB exporters, a
  node monitor, a critical-event listener.

---

## 2. The data layer — Postgres is the spine

Almost everything lives in **one PostgreSQL instance**. That's deliberate: a single
transactional store with strong constraints is the cheapest way to keep financial data
honest. The workflow engine, the dashboard, the bot, and the AI all read/write the same
DB.

- **6 schemas, ~610 tables total** (~254 in `public`):
  - `public` — the live application tables (bank, invoices, emails, events, …).
  - `raw` / `staging` / `mart` — a **classic ELT pipeline**: raw scraped/imported data
    lands in `raw`/`staging`, gets cleaned and reconciled, and the trustworthy
    aggregates live in `mart` (e.g. daily totals, exceptions, cash-variance — what the
    reconciliation dashboard reads).
  - a **functions/introspection** schema (realm helpers, the SQL-dependency graph, the
    workflow registry — see §6).
  - a **`cognition`** schema — the system observing itself (benchmarks, which AI
    "schemas" fire, bot routing decisions).
- **~250 migrations** (numbered, reviewed, reversible, applied with `ON_ERROR_STOP`).
  CI enforces the sequence is contiguous.
- **~110 views** so the AI and dashboard query stable, named shapes instead of raw
  tables.

### What the data actually looks like (approximate live scale)
| Domain | Rows | Notes |
|---|---|---|
| Bank transactions | ~22,000 | several accounts; **de-dup is mandatory** (many exact-dup rows — see §9) |
| Invoices captured | ~16,000 | the AI-extraction target |
| Emails ingested | ~75,000 | full-text searchable (GIN/`tsvector`) |
| Event bus | thousands/partition | the async backbone (see §4) |
| Audit log | ~49,000 | who/what/when for pipeline + AI actions |
| AI call ledger | ~3,000 | every model call: tokens, cost, tier, realm |
| Room-nights (hospitality) | hundreds | bookings → accommodation revenue |
| AI query surface ("slugs") | ~210 | the whitelisted queries the AI may run (see §6) |
| Dead-letter / alerts | ~1,300 / ~180 | failed-event graveyard + system alerts |

---

## 3. The security model — realms, RLS, secrets, redaction

Security here is **defense in depth at the data layer**, because the threat model is
"an AI or a workflow does something dumb with financial/personal data," not a remote
attacker.

### 3.1 Realms (the core idea)
Every sensitive row carries a **`realm`**: `owner`, `work`, `personal`, or `shared`.
`work` = the business side; `personal` = family/personal; `owner` = a god-view that sees
everything; `shared` = visible to both. The design rule is **"every table, route, and
identity must declare its realm"** — it's not optional.

### 3.2 Row-Level Security (RLS) — the enforcement
- **~117 of ~254 public tables have RLS on, with ~167 policies.** Two policy types:
  - `realm_isolation` (**RESTRICTIVE**): owner sees all; work sees work+shared; personal
    sees personal+shared. Driven by a session variable `app.current_realm`.
  - `entity_isolation` (**PERMISSIVE**): filters by which business (`app.current_entity`).
- **The subtle, important part:** RLS only bites a **non-superuser** role. For a long
  time most services connected as the DB superuser, which *bypasses RLS entirely* — so
  RLS was "armed but not firing" for them. The realm columns were used for explicit
  filtering, but the kernel-level guarantee wasn't on.

### 3.3 Database roles & the role-isolation rollout
Several custom roles exist, and a realm helper function enforces role↔realm pairing
(e.g. the "trading" role can only set realm=`work`).
- The **workflow engine** already connects as a non-superuser role with the session
  variables set — so RLS has genuinely been enforcing for the busiest writer all along.
- The **Q&A bot** runs the *risky* path (executing AI-generated SQL) as a **read-only,
  non-superuser** role in a read-only transaction with the realm pinned to the caller —
  so the AI literally cannot read across realms or write.
- The **dashboard** historically connected as superuser. A recent rollout flipped a flag
  so its shared DB helpers **`SET LOCAL ROLE`** to a non-superuser per transaction, so
  RLS actually enforces on those code paths.
  - *The landmine that made this hard:* `SET ROLE` does **not** inherit a role's default
    session variables, and the entity policy is permissive — so without explicitly
    setting `app.current_entity`, every query silently returns **zero rows**. The fix
    sets both variables every time. (`SET LOCAL ROLE` is transaction-scoped, so pooled
    connections never leak the de-privileged role — verified.)
  - **Honest status:** enforced on the *helper* paths; ~50 older "inline" endpoints
    still use a superuser connection (not broken, just not yet enforced) and are being
    migrated opportunistically. Partial by design.

### 3.4 Secrets
A **secrets vault** holds every credential (DB passwords, the cloud-AI API key, mail
OAuth, scraper logins, bot tokens). Auto-unseal is hardened with an identity file; a
**host-level watchdog** (outside the container runtime) alerts if the vault's seal state
changes — because a sealed vault takes most pipelines down, and the alerting itself
depends on the vault (a circular dependency that bit once and is now mitigated).
- **Discipline:** secrets are **never** written to files or git. A pre-commit entropy
  scan + a CI entropy job + a filename hook block secret-shaped filenames, private keys,
  vault tokens, and high-entropy hex blobs. (A rule that emerged from experience: any
  long privileged command is delivered as a *script*, because terminals wrap long pasted
  commands and orphan secret arguments.)

### 3.5 The edge & identity
A reverse proxy terminates TLS; an **SSO gateway** (a handful of users) provides login,
with the dashboard/admin surfaces behind `forward_auth` and public surfaces (a guest
form, health checks) explicitly allow-listed.

### 3.6 PII never leaves un-redacted
Before any prompt goes to a **cloud** model, it passes through **redaction** (names,
account numbers, etc.). Local models (on the in-house GPU) get raw text; only cloud
escalation is redacted. The egress firewall (§1) backs this up — only the gateway can
reach the internet.

---

## 4. The automation layer — events, workflows, pipelines

The system is **event-driven**: things happen asynchronously and durably.

- **The event bus** is a partitioned `events` table. Producers insert events; consumers
  process them; failures land in a **dead-letter** table. Idempotency keys and
  processing leases prevent double-work and stuck jobs.
- **A workflow engine** orchestrates **~22 active workflows**, stored *in the same
  database*. Major pipelines: mail ingest/classify, a **router** hub that fans out to
  the sub-pipelines, document/report ingestion, a bank-statement importer, a
  hospitality-bookings sync, an anomaly alerter, a news briefing, an image audit, and
  several watchdogs.
- **Invoice extraction** is the heaviest AI consumer — a scraper/email drops a PDF, an
  extractor turns it into text, and a model **ladder** (§5) extracts structured fields,
  escalating from the free local model to cloud only when unsure.
- *Workflow-engine gotchas now encoded as knowledge:* the runtime reads an internal
  *history* table via an "active version" pointer (editing the live nodes alone does
  nothing); a naive expression parser breaks on certain literal brace sequences;
  a "skip — already done" node returning no item once caused dead-letter floods that
  auto-paused pipelines.

---

## 5. The AI layer — tiered, cheap, mostly local

The governing idea: **do as much as possible on the free local GPU; escalate to paid
cloud only when confidence is low.** This is both a cost and a privacy decision.

### 5.1 The model ladder
- **Local (on the GPU):** a 7B workhorse model (prompt-engineered to ~95 % accuracy on
  the invoice-extraction eval), plus a couple of larger local models and an embedding
  model. The 12 GB VRAM ceiling is why nothing bigger runs locally.
- **Cloud:** a small fast model for medium escalation, a stronger model for the hardest
  cases.
- **The invoice ladder:** try the local model; accept if confidence ≥ ~0.70; else the
  small cloud model; else the strong one. In a representative week, **~2,150 local calls
  cost £0.00; ~560 small-cloud ≈ £2.20; ~27 strong-cloud ≈ £0.70.** The local model does
  the overwhelming majority for free.
- The **router** is the gateway: it picks the tier, redacts via the PII service, calls
  the model, and **writes every call to a usage ledger** (tokens, cost, latency, model,
  tier, realm, cache hits).

### 5.2 The budget system — and an honest caveat
- A **small daily cloud-spend cap** is split into priority tiers, enforced as a *floor*
  model: a **P0 floor** (financial recon, invoices, compliance) that can't be
  cannibalised, then descending tiers for email, lookups, and exploratory work. Each
  usage row is tagged to a tier by a DB trigger.
- **Honest caveat: this is "shadow mode."** The tables carry an "enforce" flag, but the
  gateway does **not** actually block over-budget calls — it logs what it *would* block.
  So the budget is *observed*, not *enforced*. The alerting around it was de-noised so
  that a busy-but-normal day doesn't page; the real signal is total spend nearing the
  daily cap.

### 5.3 The Q&A bot
The bot answers questions over chat/email. It does **not** let the AI write arbitrary
SQL — the AI may only run **whitelisted queries** (§6) or read-only queries as a
read-only role. Inbound trust is narrow (one owner, specific channels); outbound from a
single dedicated mailbox.

---

## 6. How the system remembers and knows things

There are **several distinct knowledge systems**, each for a different consumer — this
is probably the most interesting part of the architecture.

1. **A whitelisted-query surface ("slugs").** ~210 named, parameterised, pre-approved
   SQL templates, realm-scoped. The AI can only run these — it can't invent SQL against
   raw tables. A **validation trigger** `EXPLAIN`s every template at write time and
   rejects any that don't plan, so a query referencing a dropped column can't even be
   saved.
2. **A SQL dependency graph.** Built from the database's own catalog into queryable
   views + recursive functions, so "what depends on table X?" or "which views read
   column Y?" is one query instead of reading view definitions by hand. Answers the
   "why is this number wrong?" class of question.
3. **A workflow registry.** Extracted from the workflow engine's own tables: which
   workflow calls which service, reads/writes which DB tables, and triggers which other
   workflow — so tracing an event chain across ~22 workflows is a query, not a read of
   22 JSON blobs. It **bridges into the SQL graph** ("this workflow writes table X →
   which feeds these views").
4. **An MCP server** — the canonical way external AI talks to the system (tools like
   "run a whitelisted query," "read-only query," "SQL lineage," "describe a workflow").
   The rule: new AI-readable data goes through MCP, not bespoke endpoints.
5. **A `cognition` schema** — the system observing itself: which AI "schemas" actually
   fire (to prune dead ones), how the bot classified each question, model-eval results.
6. **A vector store** for semantic/RAG search (lightly used; a keep-or-kill decision).
7. **The build-agent's own file-based memory.** Separately from the system, the AI
   assistant that *builds* this keeps a memory of ~67 one-fact files plus an index
   loaded every session — typed as user facts, working-discipline feedback, project
   state, and references. This is how hard-won lessons (§9) and project context survive
   between sessions; it's deliberately separate from the system's own data.

---

## 7. Modes & flags — the system has dials

Risky changes ship **behind a flag defaulting to the old behaviour**, get canary-tested
in the live system, then flip. Examples: realm-enforcement on/off, the RLS role-drop
on/off (instant rollback by flipping back), and the budget "enforce vs shadow" mode.
This is the standard pattern for anything with blast radius.

---

## 8. How the system checks itself

Multiple independent guardrails, because it runs unattended:

- **A deep self-test harness** — ~50 checks, currently all green: every container
  running, the secrets vault unsealed, an RLS test suite, the expected workflows
  active, all HTTP probes healthy, all metrics exposed, the nightly backup fresh +
  snapshots present, data fixtures, and a check that **every static SQL query in the
  app still plans against the live schema** (a permanent guard against the "stale
  column" bug class — see §9).
- **CI** — lints shell/Python syntax, an entropy scan, and a migration-contiguity
  check. (No live DB; DB-dependent tests are host scripts.)
- **In-database triggers** — query-template validation, usage-tier auto-stamping, and
  the deny-by-default RLS policies.
- **Watchdogs** — a host-level vault watchdog (outside the container runtime), a
  cron-health watchdog, a workflow-errors watchdog, GPU-recovery, backup-freshness.
- **Monitoring** — Prometheus scrapes custom DB metrics + node/GPU; Alertmanager → a
  bridge → chat. Alerts are deliberately kept *actionable* (heartbeat/quota noise was
  silenced — a quiet channel is one people actually read).

---

## 9. The tricks & the scar tissue (hard-won gotchas)

These are the landmines that actually bit, now encoded so they don't again — they
explain a lot of the defensive code:

- **Financial rows duplicate.** The bank table has many exact-dup rows; **every** sum
  must de-dup first. A reconciliation-error post-mortem produced a set of mandatory
  rules (compute-and-assert totals, DB-derive every line, unique symmetric join keys,
  statement-anchored dates, canonical-source dedup, "an entity is not one account,"
  always cross-foot).
- **`SET ROLE` drops a role's default session variables** → a permissive policy fails
  closed → silent zero rows. The role-isolation fix exists because of this.
- **Postgres doesn't short-circuit `OR`** in policy expressions — a cast inside an `OR`
  errors even when a guard branch "should" have prevented it; needs a CASE/regex guard
  before any cast.
- **STORED generated columns read NULL in BEFORE triggers** if the source column isn't
  in the UPDATE — corrupted a batch of rows once before it was caught.
- **Container bind-mount inode trap** — atomic-replace editors (and moving a host dir)
  silently break a running container's bind mount; it keeps reading the old data until
  restart. This is why moving live-mounted dirs is done by container-recreate, never a
  naive symlink.
- **Botched bulk-edit corruption** — more than once, a scripted edit landed lines in
  the wrong place (corrupted route handlers; a broken script; a DB write against
  non-existent columns). The self-test SQL check + the query-validation trigger are the
  permanent defense.

---

## 10. What's been achieved — and an honest assessment

### Solid and working
- A single, constrained, **heavily-audited financial datastore** (~22k bank lines, ~16k
  invoices, ~49k audit rows) with a real ELT pipeline (raw→staging→mart).
- **Mostly-free AI extraction** — the local GPU does the bulk; cloud spend is well under
  £1/day.
- **Realm + RLS isolation** genuinely enforcing for the highest-risk paths (the workflow
  engine, the bot's AI-SQL, and now the dashboard helper paths).
- **Self-verifying** — a green deep self-test, a green CI, watchdogs, and a guardrail
  that catches the recurring "stale schema" bug class automatically.
- **Recoverable** — vault auto-unseal hardened after seal incidents; nightly
  deduplicated backups; code mirrored off-host with a mandatory entropy scan before
  every push.
- **Self-describing** — the SQL graph + workflow registry + query surface + MCP mean the
  system can now *explain its own structure* to an AI.

### Fragile / partial / deferred (the honest list)
- **Quota enforcement is shadow-only** — nothing actually blocks overspend; it relies on
  the cap being soft.
- **RLS rollout is partial** — ~50 inline endpoints still run as superuser (not enforced;
  not broken). Opportunistic migration.
- **Backups are local-first** — the dedup backup is on the same NVMe; the off-host copy
  is *code*, not the *data*. A true off-host **data** backup is the most important
  resilience hole.
- **Single points of failure** — one machine, one GPU, one database, one unmirrored
  bulk disk. Fine for a personal system; worth naming.
- **Ingestion can over-fire** — a historical dead-letter backlog and a once-large import
  backlog show the pipelines need (and now have) guards.
- **Some third-party integrations are degraded** — one portal needs a browser-automation
  rewrite, one export is manual, one accounting integration is API-blocked, the vector
  store is barely used.
- **Doc drift** — long design docs lag reality; the live system is the source of truth.

### The shape of it, in one breath
A privacy-first, single-box, event-driven, Postgres-centred administrative engine that
ingests a small business's paperwork, extracts it cheaply with a local-first AI ladder,
keeps it honest with realm/RLS isolation and obsessive auditing, watches and tests
itself, and — increasingly — can describe its own internals well enough to be safely
operated by an AI. It is not bullet-proof (shadow quotas, partial RLS, local backups),
but the failure modes are known, named, and mostly guarded.
