# Codex task — Speed / Security / Efficiency audit of the Home AI Administrative Engine

## Your role
You are a senior staff engineer doing a **read-only investigation** of this codebase.
Produce a prioritised, evidence-backed set of recommendations across three axes:
**speed (latency/throughput), security, and efficiency (cost/resource/maintenance)**.
You are auditing, not refactoring. Do **not** modify code, schema, secrets, containers, or
the database in this pass. Output findings only.

## Hard boundaries (read these first — violating any is a failed task)
- **Read-only.** No `git commit`, no `git push`, no edits to files, no `docker compose up/down/restart`,
  no writes to PostgreSQL, no n8n workflow activation/deactivation. Inspection commands only
  (`grep`, `cat`, `ls`, `docker ps`, `docker inspect`, `SELECT` against a read replica/role only if asked).
- **Respect the global kill switch.** This system has `SELECT value FROM static_context WHERE key='system.state'`.
  Do not trigger pipelines or DB writes. You are not running the pipelines, just reading the code.
- **Never print secrets.** If you find a secret in a file, report the *location and the fact that it's
  there* as a security finding — do NOT echo the secret value into your output.
- Read `/home_ai/AGENTS.md` and `/home_ai/SPEC.md` (relevant sections) before forming conclusions.
  The architecture's invariants are defined there; flag violations against *those* rules.

## System context (so you don't re-derive it)
Local-first, event-driven data platform on a single P620 box (Ubuntu 22.04 + Docker).
- **Backbone:** a `events` table (partitioned by month). Deterministic routing → AI enrichment
  → PostgreSQL write → event emit.
- **Orchestration:** n8n (workflow JSON). AI workers are stateless enrichment only.
- **Secrets:** HashiCorp Vault — *no secrets in files or .env* is an enforced rule.
- **Isolation:** PostgreSQL Row-Level Security keyed on `app.current_entity` (4 entities:
  1=pub Ltd, 2=property Ltd, 3=Personal, 4=Family). Realm split (owner/work/personal) also exists.
- **Microservices** (`/home_ai/services/`, mostly FastAPI/Python): bot-responder, build-dashboard,
  critical-listener, google-fetch, homeai-data-proxy, homeai-frontend, homeai-litellm, homeai-mcp,
  homeai-presidio, homeai-vault-agent, llm-router, markitdown, model-evaluator, pdfplumber,
  playwright, review-scraper, wa-bridge.
- **LLM tier:** local Ollama models (qwen2.5:7b hot tier) + LiteLLM router + Anthropic API
  with a £3/day budget cap. A homeai-mcp server (:8765) is the canonical external AI surface.
- **Data sources of truth (never to be overridden):** Xero=accounting, Dext=invoices,
  Bank=transactions, ICRTouch=EPoS, Caterbook=accommodation.

## Where to look
- App code: `/home_ai/services/*` (FastAPI services), `/home_ai/*.py` (pipeline + frontend-gen scripts),
  `/home_ai/lib/` (shared libs incl. `claude_call.py`).
- Data layer: `/home_ai/postgres/init-db.sql`, `seed-data.sql`, migrations (`V*.sql`).
- Orchestration: `/home_ai/.claude/n8n-exports/` (workflow JSON), `/home_ai/docker-compose.yml`.
- Config: `/home_ai/config/`, `.mcp.json`, any compose/env templates.
- **Exclude from analysis:** `node_modules/`, `.venv/`, `.git/`, vendored deps, `*.bak`, build artifacts.
  (The repo is ~13G; almost all JS/TS line count is vendored — focus on first-party code only.)

## What to investigate — by axis

### 1. SPEED (latency & throughput)
- **PostgreSQL:** missing indexes on hot query paths (esp. `events`, `bank_transactions`,
  partitioned-table queries that don't prune by month). N+1 query patterns in services.
  Sequential scans on large tables. Connection-per-request vs pooling. Are reads on the
  partitioned `events` table actually partition-pruning?
- **n8n pipelines:** per-item loops doing one DB round-trip each; synchronous external calls
  that could batch; missing pagination causing full re-fetches.
- **LLM path:** prompt-cache misses (known thresholds: Haiku 4.5 needs ~5k+ tokens, Sonnet ≥1024),
  oversized prompts, calls that could route to the cheap local tier but hit the API, retries
  without backoff. Look at `lib/claude_call.py` and any raw-HTTP callers.
- **Services:** blocking I/O in async handlers, work done at request time that could be cached
  or precomputed (e.g. dashboard aggregations), repeated PDF/OCR work without a cache.

### 2. SECURITY
- **Secrets:** any secret material committed to files, `.env`, n8n Code nodes, or compose files.
  Entropy-scan first-party YAML/JSON/SQL/py (bootstrap-written hex secrets evade filename filters).
  Report location only, never the value.
- **RLS integrity:** writes missing `SET LOCAL app.current_entity` (enforced rule — find any path
  that bypasses it). Services connecting as the `postgres` superuser instead of a scoped role.
  RLS policies with `OR` short-circuit / cast-before-guard bugs. `SET ROLE` paths that drop
  `ALTER ROLE SET` GUC defaults (entity_isolation is PERMISSIVE → missing GUC = silent 0 rows
  OR silent full access — determine which).
- **Event integrity:** event payloads inserted without HMAC-SHA256 signing; processing without
  an idempotency_key check (both are enforced invariants — find violations).
- **PII handling:** AI prompts using raw `body_text` instead of the sanitised `body_text_safe`
  (Presidio path). Any PII reaching an external API.
- **Network/exposure:** services published to host/Tailscale that shouldn't be; auth gaps
  (Authelia forward-auth coverage); CORS; missing input validation on FastAPI endpoints;
  SQL built by string concatenation (injection) vs parameterised.
- **Dependencies:** known-vulnerable pinned versions in first-party `requirements.txt` /
  `package.json` (flag, don't auto-bump).
- **Webhooks/inbound trust:** which endpoints accept external input and what validates the sender.

### 3. EFFICIENCY (cost / resource / maintainability)
- **LLM spend:** calls that could use the local hot tier instead of paid API; model over-selection
  (Sonnet/Opus where Haiku/qwen suffices); redundant calls; the £3/day budget allocation vs actual usage.
- **Compute/memory:** containers with no resource limits; the GPU driver-mount pattern (CDI vs legacy
  `deploy.resources.reservations.devices`); duplicate/idle services.
- **Storage/data:** the known `bank_transactions` exact-duplicate-rows issue and any sum() that
  doesn't de-dup first; tables without retention/partition-drop policy; large unindexed text columns.
- **Code health:** duplicated logic across services that should be in `lib/`; raw-HTTP Anthropic
  callers that haven't adopted the `claude_call.py` retry wrapper (max_retries=8); dead scripts
  in `/home_ai/*.py` (many look like one-off frontend patchers — flag candidates for archival).
- **Reliability-as-efficiency:** pipeline patterns that cause DeadLetter floods / auto-pause
  (noOp-skip returning no item, parse-fail throwing NodeError). These burn operator time — flag the class.

## Method
1. Start by reading AGENTS.md + SPEC.md to load the invariants.
2. Map first-party code (exclude vendored). Build a quick inventory of services and entry points.
3. For each axis, grep/inspect for the specific patterns above. Prefer evidence over speculation.
4. For DB findings, read the schema/migrations rather than querying live data.
5. Cross-check any finding against the enforced rules in AGENTS.md before reporting it.

## Output format
Produce a single markdown report, `codex-audit-findings.md`, structured as:

1. **Executive summary** — 5–8 bullets, the highest-leverage findings across all axes.
2. **Findings table**, sorted by priority. Each row:
   `ID | Axis (Speed/Security/Efficiency) | Severity (Critical/High/Med/Low) | Title | Evidence (file:line) | Effort (S/M/L)`
3. **Detailed findings** — one section per finding:
   - What it is and *where* (`file:line` references, clickable).
   - Why it matters (impact, quantified if possible — e.g. "runs N times per pipeline item").
   - Concrete recommendation (what to change, not a vague gesture).
   - Risk/effort of the fix and any ordering dependency.
4. **Quick wins** — the subset that is High-impact + Low-effort, called out separately.
5. **Things I could not verify** — anything needing live data, a running container, or a decision
   from the owner. Be explicit about assumptions.

Prioritise ruthlessly. A short list of true, evidence-backed, actionable findings beats a long
list of generic best-practice advice. If you assert something is slow/insecure/wasteful, show the
line that proves it.
