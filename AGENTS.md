# Home AI Administrative Engine — AGENTS.md
# Portable across all coding tools. All agents read this.

## Read first, every session
1. `/home_ai/HOME-AI-STRETCH.md` — known issues, fixes, model-stack updates,
   pending decisions. ALWAYS read before SPEC.md or anything else.
2. This file (AGENTS.md) — operational rules + build state.
3. SPEC.md — only the relevant section for the current step.

## System
Local-first event-driven data platform. P620 + Ubuntu 26.04 + Docker.
Full spec: /home_ai/SPEC.md  (read relevant section before each step)

## Architecture
Events table (partitioned by month) is the system backbone.
n8n = pipeline orchestration. AI workers = stateless enrichment only.
Vault = all secrets. PostgreSQL RLS = entity isolation.
Deterministic routing → AI enrichment → PostgreSQL write → event emit.

## Entity IDs
1=Atlantic Road Trading Ltd (pub/inn/restaurant)
2=Atlantic Road Estates Ltd (7 investment properties)
3=Personal
4=Family (3 children ages 8, 10, 16)

## Source of truth (never override these)
Xero=accounting | Dext=invoices | Bank=transactions | ICRTouch=EPoS | Caterbook=accommodation

## Build rules (enforced by hooks — not optional)
- NEVER write any secret to a file. Vault only. No .env with secrets.
- ALWAYS prepend SET LOCAL app.current_entity before any PostgreSQL write.
- ALWAYS use body_text_safe (sanitised), never body_text, in AI prompts.
- ALWAYS sign event payloads (HMAC-SHA256) before INSERT to events table.
- ALWAYS check idempotency_key exists in events before processing.
- NEVER commit: CLAUDE.local.md, *.env, *secret*, *credential*, *password*

## Context management
- Watch context indicator. Run /compact before 60% capacity.
- When compacting: /compact Preserve phase+step number, confirmed Vault secrets,
  confirmed running Docker services, confirmed PostgreSQL tables, idempotency key formats.
- Never let auto-compaction fire during Vault, database, or Docker steps — it is lossy.

## Parallel domain routing
Spawn parallel subagents for independent domains:
- microservices (pdfplumber, garmin, playwright) — safe to parallelise
- n8n pipeline workflows — each is independent JSON, safe to parallelise
- monitoring config — safe to parallelise
Sequential only (never parallelise): PostgreSQL schema, Vault config, docker-compose.yml

## Subagent model
For focused subagent tasks: export CLAUDE_CODE_SUBAGENT_MODEL="claude-haiku-4-5-20251001"
Main session for complex reasoning: default (Sonnet or Opus)

## Global kill switch
Check system.state before any action that writes to the database or triggers a pipeline:
  SELECT value FROM static_context WHERE key='system.state';
If state='paused': stop, log, do not process. Do not override the pause.
Pause/resume via /pause-all and /resume-all slash commands only.

## Context7 MCP (recommended — install before Phase 5 RAG work)
Context7 serves library documentation at exact versions as tool calls.
Prevents hallucinated API signatures on: n8n nodes, Qdrant Python client,
asyncpg, HashiCorp Vault API, garminconnect, FastAPI, exllamav2.
Install: npx -y @upstash/context7-mcp (or via MCP settings in Claude Code)

## Key paths
Stretch:     /home_ai/HOME-AI-STRETCH.md   (READ FIRST every session)
Spec:        /home_ai/SPEC.md
Docker:      /home_ai/docker-compose.yml
Startup:     /home_ai/start.sh   (run after every reboot — see Startup below)
Schema:      /home_ai/postgres/init-db.sql
Seed:        /home_ai/postgres/seed-data.sql
Migrations:  /home_ai/postgres/migrations/
Services:    /home_ai/services/
n8n backups: /home_ai/.claude/n8n-exports/
Skills:      /home_ai/.claude/skills/
Commands:    /home_ai/.claude/commands/

## Startup
After every reboot, run `./start.sh` from /home_ai. The script:
1. Verifies prereqs (docker, jq, vault container running).
2. Prompts for 3 of 5 unseal keys if Vault is sealed (silent input).
3. Prompts for a Vault token with read access to the infrastructure secrets.
4. Fetches POSTGRES_PASSWORD, N8N_DB_PASSWORD, METABASE_APP_PASSWORD,
   REDIS_PASSWORD, GRAFANA_ADMIN_PASSWORD, OPEN_WEBUI_SECRET from Vault.
5. Issues a fresh 24h-TTL n8n token via `vault token create -policy=n8n-policy`.
6. Runs `docker compose up -d` with all env vars exported.
7. Waits up to 60s for postgres + redis + vault to report healthy.
8. Trap clears all secrets from process env on exit (any path).

Never run bare `docker compose up -d` after this script exists — env vars
won't be set, services will recreate with empty passwords and crash-loop.
Always go through start.sh.

## Skill gotchas (update as failures are discovered during build)
- Claude will try to name containers differently to docker-compose — always use
  docker compose ps to get the actual running container name before exec commands.
- Claude will try to write directly to events without idempotency check — hook blocks this.
- Claude will inline secrets in Code nodes — hook blocks writes to .env files.
- Claude will write SQL without SET LOCAL app.current_entity — hook enforces this.
- Metabase needs its own database + role (metabase_app), NOT the homeai app DB
  with homeai_readonly. Liquibase needs CREATE on its metadata schema; granting
  CREATE to homeai_readonly defeats RLS/least-privilege. Add homeai as a
  Metabase Data Source via the UI, querying with homeai_readonly.
- Postgres 15+ revokes CREATE on schema `public` from the PUBLIC role. Any
  third-party tool that bootstraps its own metadata tables (Metabase,
  Liquibase-using apps, etc.) must own its database, not just have a login.
- When giving the user any unseal/rekey/root-token procedure, lead with an
  explicit "do not paste keys into this chat — run in your terminal" warning
  *before* listing the commands. Don't wait for the user to leak before
  flagging it.
- psql `:'var'` substitution does NOT work inside `$$…$$` dollar-quoted
  blocks. For runtime SQL generation with substituted values, build the
  statement at the top level: `SELECT format('… %L', :'var') WHERE NOT
  EXISTS (…) \gexec`.
- Schema changes after first boot belong in `postgres/migrations/V_n__*.sql`,
  not direct `psql` statements. Migrations must be idempotent. See
  `.claude/decisions/2026-05-01-migrations-naming.md`.
- `static_context` emits no automatic events anymore. The original
  `static_context_change` AFTER UPDATE trigger (which wrote
  `payload_signature='init_placeholder'`, violating the HMAC rule) was
  dropped by V4. **Anything that mutates `static_context` and wants to emit
  a corresponding `system.config_change` event must build the event in
  application code**: compute HMAC-SHA256 over the canonical-JSON payload
  using `PAYLOAD_HMAC_KEY` from env, then INSERT to `events` with proper
  `idempotency_key` and `audit_log` row. Reference: model-evaluator
  `deploy_model` endpoint and the n8n `email-pipeline.json` Sign + Emit node.

## Build state
Phase: 1 | Milestone: C closed + Phase 2 hands-off pre-built. Last completed: Sprint 3 + Bucket 2 (selftest 52/52 PASS).
SPEC v5.3 installed 2026-05-08 22:23. Refactors completed in same session:
  R1: gmail-ingest-v1 — Parse Ollama Response, Parse Haiku Response, Sign Payloads, Write Audit Log
      patched. AI worker Code nodes now return OutcomeObject {status, confidence, reasoning,
      data, requires_human, worker, tier_used}; status derived as success/escalate/fail vs
      `ai.thresholds.email_classifier.min_confidence` (escalate band: confidence ≥ threshold*0.85).
      audit_log.ai_parsed now stores OutcomeObject JSONB (was clsf_payload). Hot tier marked
      tier_used='hot', Haiku marked tier_used='haiku'. Workflow topology unchanged — IF Confidence
      OK still routes to Haiku escalation; the OutcomeObject is data-side enrichment.
  R2: bank-csv-import-v1 — replaced JSON-input webhook with multipart upload that forwards the
      CSV to pdfplumber:8003/parse-csv, then maps the parsed rows (handles UK bank column variants
      including split Money In/Money Out). Single bank.imported event still emitted; per-row
      bank.transaction events deferred until bank_pipeline (Xero matching) is built.
  R3: V12 migration — `ensure_next_event_partition()` now targets month+2 (was +1) per SPEC v5.3
      Pipeline 11. events_2026_07 auto-created on apply.
Step 17 monitoring (2026-05-08 22:55):
  - Added `postgres-exporter` service to docker-compose (image: prometheuscommunity/postgres-exporter
    v0.15.0; networks ai-internal + ai-monitoring; env DATA_SOURCE_NAME via $POSTGRES_PASSWORD).
  - Enabled n8n metrics: `N8N_METRICS=true` env var on n8n service. /metrics endpoint live on :5678.
  - Updated monitoring/prometheus.yml to scrape postgres-exporter:9187 instead of postgres:5432.
    Vault scrape commented out — needs `unauthenticated_metrics_access = true` in vault.hcl
    listener block + restart, deferred to Phase 2 alongside auto-unseal.
  - All 3 active scrape targets UP: prometheus (self), n8n, postgres.
  - Grafana provisioning: datasources/prometheus.yaml (uid=prometheus, default) +
    dashboards/ provider config + dashboards/home-ai-baseline.json (8 panels: leader/health stats,
    n8n exec rate by status, p50/p95 duration, postgres connections by state, eventloop lag).
    Mounted at /etc/grafana/provisioning + /var/lib/grafana/dashboards (read-only).
  - Grafana admin password env var only applies on first init — Grafana is now drift-locked to
    whatever admin pw was set in UI. To reset: docker exec homeai-grafana grafana-cli admin
    reset-admin-password '<NEW>'.
Long hands-off sprint (2026-05-08 23:00–23:30):
  Tier A — Operational visibility:
    A1: postgres-exporter custom queries.yaml (9 business metrics: events_pending, events_status,
        events_overflow, dead_letter, dead_letter_recent, audit_log_recent, bank_unreconciled,
        emails_review_queue, events_partition_rows, events_processing_lease_age, +
        stale_lease_recovery_recent from V14).
    A2: Pipeline Health Grafana dashboard (13 panels) auto-provisioned at uid=home-ai-pipelines.
    A3: 8 Prometheus alert rules (DeadLetterFlood, DeadLetterGrowing, EventsOverflowNonZero,
        StuckProcessingLease, PendingEventsBackup, PostgresConnectionSaturation, ScrapeTargetDown,
        N8nEventLoopLag).
    A4: V13 cleanup migration — archived 11,008 historic dead_letter rows to dead_letter_archive,
        added UNIQUE constraint on dead_letter.event_id, fixed `recover_stale_leases()` to
        atomically UPDATE events.status='failed' alongside dead_letter INSERT (was the root cause
        of the 2k/hr dead_letter flood).
    A5: V14 — recover_stale_leases() now writes audit_log row when recovery activity > 0;
        new metric `stale_lease_recovery_recent_*` exposed.
  Tier B — Pipelines:
    B1: Master Router added `document.received` → P9 webhook + `child.event.detected` → P8 webhook
        routes (Switch + httpRequest trigger nodes); existing 7 routes preserved.
    B2: `report-ingestion-v1` workflow built (P9). 16 nodes including Vault Gmail OAuth refresh,
        Gmail attachment fetch, pdfplumber routing by MIME, Haiku report_parser with
        OutcomeObject + audit_log ai_parsed JSONB. Active.
    B3: DEFERRED — Poller has attachment data but P9 needs emails.id which only exists after
        gmail-ingest-v1 runs. Cross-workflow contract redesign needed; revisit in next session.
    B4: `nanny-v1` workflow built (P8). Haiku nanny_classifier with 3 placeholder children seeded
        in `children` table (PLACEHOLDER A/B/C — user should UPDATE with real names + DOBs).
        OutcomeObject pattern, conditional medical_history INSERT. Active.
    B5: `gmail-ingest-v1` patched: Sign Payloads now also produces child_payload/child_sig/idem_child;
        new `INSERT child.event.detected` Postgres node added between INSERT email.classified
        and Invoice or Report? — emits only when ai_category='school-medical'. Active.
  Tier C — Backup:
    C1: `/home_ai/scripts/backup-nightly.sh` — pg_dump homeai + tar n8n_data/vault_data + restic
        backup of config tree. Repo at `/home_ai/backups/restic-local`, password file at
        `/home_ai/backups/.restic-pw` (chmod 600, NOT in Vault per SPEC). 7-daily/4-weekly/6-monthly
        retention. First snapshot 0f85747f (636 KiB). Cron installed: `0 3 * * *`.
        TODO: repoint to NAS once `/mnt/mycloud` is mounted (set `RESTIC_REPO` env override).
    C2: folded into C1 (vault_data already tar-archived into staging then captured by restic).
  Tier D:
    D1: `/home_ai/.claude/n8n-webhooks.md` regenerated — registry of 4 active webhooks +
        Master Router routing table + reachability/test patterns.
    D2: NOT DONE — DELETE of placeholder bank_accounts.id=2 + 7 transactions awaits user OK.
    D3: schema audit completed at `.claude/decisions/2026-05-08-schema-audit-spec-v5.3.md`.
        Drift findings: 4 SPEC §3.2 omissions (entity_id missing from accommodation/epos/till
        snippets despite RLS requiring it; score_date missing from model_scores). Implementation
        is correct; SPEC has gaps. No code action needed.

8 active n8n workflows: bank-csv-import-v1, gmail-ingest-v1, partition-maintenance-v1,
  report-ingestion-v1, nanny-v1, test-master-router, watchdog-n8n-errors, QMKzaCFrKBS4ewWm.
Sprint 2 (2026-05-09 ~00:00):
  SPEC edit — Dext API removed: Pipeline 2 rewritten to make pdfplumber/MarkItDown + Haiku the
    sole automated extraction path. Idempotency key now `invoice_{sha256(supplier+gross+date+entity)}`.
    secret/dext + Vault policy + Gate C "Dext priority" test + diagnostic warning all stripped.
    Dext kept as Jo's manual review tool for 60-day parallel comparison. Reflected in STRETCH §3.3
    + Pending Decisions. Memory entry: project_dext_no_api.md.
  A1: Gmail Poller (QMKzaCFrKBS4ewWm) Sign+Build SQL gated with WHERE NOT EXISTS — re-fetched
    Gmail messages no longer create duplicate event rows every 15 min.
  A2: Poller account hardcode 'account1' → 'personal1' in Parse + Sanitise (matches actual
    Vault path secret/gmail/personal1).
  A3 (was B3 deferred): Poller now walks message.payload.parts and emits one document.received
    event per attachment with payload `{gmail_message_id, attachment_id, filename, mime_type, size}`
    (no email_id). Idempotency key `report_{sha256(gmail_message_id+filename)}`. P9 updated:
    Validate Event accepts missing email_id; Idempotency Check uses LEFT JOIN on emails;
    Upsert resolves email_id from emails by gmail_message_id with NULL fallback.
  B1: Alertmanager added (`prom/alertmanager:v0.27.0`, port 9093 internal-only). prometheus.yml
    routes via `alerting:` → `homeai-alertmanager:9093`. n8n workflow `alert-sink-v1` receives
    Alertmanager webhooks at `/webhook/prom-alert`, flattens batches, UPSERTs system_alerts,
    writes audit_log row.
  B2: alert-sink branches on `auto_pause` flag. When alertname == DeadLetterFlood and status ==
    firing, UPDATEs static_context.system.state to paused. Master Router's Kill Switch Check
    catches it on next 30s cycle. Verified end-to-end with synthetic flood alert.
  C1: hmac-verifier-v1 workflow — daily 04:30 cron samples 100 random recent events,
    recomputes HMAC, compares to stored signature, writes audit_log row with verified/failed
    counts. New Prometheus metrics `hmac_verification_recent_{verified,failed,sample}_24h`.
  C2: Slash commands audited — pause-all.md and resume-all.md updated to use direct
    psql UPDATE (the system-control webhook the originals referenced doesn't exist). All
    documented commands (12) covered or are Claude Code built-ins.
  D1: `/home_ai/scripts/backup-all.sh` weekly DR backup drafted (DB dumps for both DBs +
    n8n CLI workflow export + vault_data tar + restic with separate `homeai-weekly` tag).
    First manual run 8.995 MiB, snapshot 81fd984d. Cron line documented in script header
    but NOT installed — install manually after verifying remote git push step is safe.
  D2: `/home_ai/postgres/tests/rls-test-suite.sql` — runs as homeai_pipeline (refuses to run
    as superuser), tests emails + events RLS across `app.current_entity` values 'all', '1',
    '2', empty, non-numeric. All inserts in transactions that ROLLBACK. Passed first run.

9 active n8n workflows now: + alert-sink-v1, hmac-verifier-v1.
Sprint 3 (2026-05-09 ~00:30):
  SP3-A1: services/markitdown/ deployed — MarkItDown microservice, /convert
    endpoint, port 8004. Sibling to pdfplumber for non-PDF (image, Word,
    HTML, etc) attachments.
  SP3-A2: invoice-pipeline-v1 live — webhook /webhook/invoice-pipeline,
    14-node flow: validate → find attachment via document.received events
    → fetch from Gmail → pdfplumber/markitdown by MIME → Haiku
    invoice_extractor → OutcomeObject → INSERT invoices +
    supplier_invoice_history rolling stats + emit invoice.unmatched event +
    audit_log. Idempotency `invoice_{sha256(supplier+gross+date+entity)}`.
    Active. Xero match step stubbed (waits for P3 in Phase 2).
  SP3-A3: gmail-ingest-v1 already emits invoice.detected with WHERE NOT
    EXISTS check. Master Router now routes invoice.detected → P2 webhook
    (added Trigger Invoice Pipeline httpRequest node).
  SP3-B1: scripts/bootstrap.sh — Ubuntu 26.04 fresh-machine setup,
    idempotent, --dry-run mode. Installs apt packages, NVIDIA toolkit,
    Tailscale, configures UFW. Doesn't auto-clone or auto-start.
  SP3-B2: scripts/restore.sh — restore from backup-all.sh staging dir OR
    `restic latest` snapshot. Restores DB + n8n workflows + vault_data tar.
    Confirms before destructive ops; --yes / --dry-run modes.
  SP3-B3: scripts/schema-drift-check.sh — diffs running schema vs
    init-db.sql + V2..V15 in throwaway postgres. First run flagged drift
    (mainly n8n system tables); allowlist still leaks FK continuation
    lines — refinement is a debt item.
  SP3-C1: watchdog-n8n-errors patched — added 'Record system_alerts' node
    in parallel with Telegram path so errors land on the dashboard even
    before the Telegram bot is wired. No overlap with auto-pause (different
    signal: execution_entity errors vs dead_letter floods).
  SP3-C2: .claude/hooks/no-secrets-in-files.sh + sql-rules.sh + install.md.
    PreToolUse hooks for secret-file paths, INSERT INTO events without
    payload_signature, INSERT into RLS-scoped tables without RLS context.
    Smoke-tested. NOT installed by default — opt-in via paste into
    ~/.claude/settings.json (snippet in install.md).
  SP3-C3: .claude/decisions/2026-05-09-gate-c-readiness-scorecard.md —
    18 PASS / 7 PARTIAL / 16 BLOCKED-on-user / 0 FAIL across 41 SPEC §6.5
    items. Total user-side work to fully close Gate C: ~75 min across 8
    unblockers.

12 active n8n workflows now: + invoice-pipeline-v1.
17 active services: + markitdown.
Tonight (2026-05-09 00:30–01:30) — Sprint 3 A–F + Bucket 2:
  SP3-A ai_usage logging: 4 AI workflows (gmail-ingest Haiku branch, nanny-v1,
    report-ingestion-v1, invoice-pipeline-v1) now INSERT into ai_usage with
    prompt/completion tokens, tier, escalated flag. Spend tile + Velocity tile
    populate live as soon as a real pipeline run fires.
  SP3-B P2 fixture: /home_ai/postgres/tests/p2-invoice-fixture.sql runs as
    homeai_pipeline, exercises invoice INSERT + idempotency replay +
    supplier_invoice_history rolling stats + audit_log OutcomeObject. ROLLBACK
    so no real data created. Passes.
  SP3-C drift detector: Python normaliser replaces brittle awk allowlist;
    output dropped from 2052 → 56 lines, all of which are cosmetic column-
    order diffs from later ALTER TABLEs.
  SP3-D ADRs: 5 written in .claude/decisions/ — Outcome-Native, B3 contract,
    alert auto-pause, Dext removal, Gmail Poller idempotency.
  SP3-E sanitiser fixture: /home_ai/postgres/tests/sanitiser-fixture.js,
    30/30 cases pass. node-runnable.
  SP3-F Dreaming Workflow H (full, not just stub): n8n workflow `dreaming-v1`
    daily 02:00 → aggregate audit_log failures → Haiku → write
    /home_ai/storage/dreaming/heuristics.md (capped 2KB). Active.
  B2-Diag diagnostics-v1: daily 06:30, 10 health tests via single SQL,
    forwards critical/warning to alert-sink (which routes via Alertmanager
    pattern). diagnostic_history rows + audit_log summary. Active.
  B2-Cleanup cleanup-v1: weekly Sunday 04:00 — prunes >30d successful
    executions, >30d resolved alerts, >90d diagnostic_history, >90d
    dead_letter_archive. Then VACUUM ANALYZE on hot tables. Active.
  B2-Bench: services/model-evaluator/benchmark_tasks.py — full SPEC §6a.4
    suite (10 email samples, 5 invoice texts, 3 reports, speed prompts).
    Runner stays Phase 2 but suite ready.
  B2-PARA: .claude/vault/{Projects,Areas,Resources,Archives}/ skeleton
    with seed area+resource notes.
  B2-SLO: third Grafana dashboard at uid=home-ai-slo — pipeline success rate
    24h, audit timeseries by pipeline/result, stale lease activity, HMAC
    verifier coverage, pending events tables. Auto-provisioned.
  B2-Authelia: scaffolding only (compose service block commented). Config at
    security/authelia-v2/configuration.yml + users_database.yml.template +
    scripts/authelia-bootstrap.sh interactive setup. User runs bootstrap
    when ready (interactive password + browser-side TOTP enrol).
  Selftest: scripts/selftest.sh — 52 checks across services, Vault, Postgres,
    workflows, HTTP probes, custom metrics, backups, fixtures.
    First run: 52/52 PASS after fixing audit_log_recent zero-row metric drop.

14 active n8n workflows now: + dreaming-v1, diagnostics-v1, cleanup-v1.
18 active services unchanged (Authelia not yet activated).
Dashboard v3 (Mission Control) — 2026-05-09 ~01:35:
  - 30s heartbeat progress bar at top; CRIMSON + overlay banner if any of
    /api/snapshot or /api/hardware fails. Shows the failing endpoint.
  - Outcome registry rewritten as log-stream cards (left-border colour by
    outcome). Outcome Primitive taxonomy: Validated / Escalated /
    Hallucination? / Human required. Confidence colour-graded.
  - Hardware moved to top-bar mini-tray (Vault badge, CPU/RAM/Disk inline).
    Vault SEALED triggers prominent red badge + lockdown overlay.
  - Dedicated VRAM heatmap row per GPU; amber>75% / red>90% with explicit
    OOM warning text.
  - Dreaming "🧠 Dreaming…" pulse on the GPU/Agents panel when dreaming-v1
    has an in-flight execution. Last-run relative time when idle.
  - Tasks: hands-off + needs-you side-by-side; needs-you sorted by impact
    (top-3 highlighted with #N unblocks badge).
  - Velocity sparkline (7-day £ saved) inline in hero strip.
  - Context Pressure tile: SPEC.md (61.3k tok), AGENTS.md (6.6k tok),
    HOME-AI-STRETCH.md (15.5k tok) → 41.7% of 200k. Coloured amber>60% /
    red>85%.
  - Shadow Run button placeholder on escalated/hallucination/human rows
    (tooltip explains it's wired for next sprint).
  - Backdrop blur 20px + JetBrains Mono for IDs/IPs/models for clarity.
  - 3 new endpoints: /api/context-pressure, /api/dreaming, /api/spend?days=N
    (now returns velocity-£ series, not raw token spend).
  - SPEC.md / AGENTS.md / STRETCH bind-mounted ro into the dashboard
    container so context-pressure can read them live.
V16 init-db.sql column-order fix: entity_id moved to end of three RLS-scoped
  daily-report tables to match how live schema laid them out (added by an
  early ALTER TABLE). schema-drift-check.sh now reports zero drift.
Selftest 52/52 PASS — final run after all changes.

Hybrid Compute / Sovereignty (2026-05-09 ~02:00):
  V17 audit_log.provider + ai_usage.provider columns. Backfilled 31 rows
    via heuristic (claude-* → anthropic, qwen/phi/llama/mistral → local).
    Going forward: 4 AI workflows write provider explicitly. gmail-ingest-v1
    audit_log uses CASE on ai_model so it tags correctly per-call.
  Ollama MCP config drafted at .claude/mcp-ollama.json — opt-in (paste into
    ~/.claude.json). Exposes the local box as `local_worker` tool with
    routing guidance (use local for summarisation/log/schema, cloud for
    code surgery / multi-file pivots).
  Dashboard backend: 4 new endpoints — /api/sovereignty (local-vs-cloud
    split + £ saved estimate at £0.01/1k tokens), /api/leaderboard
    (latest model_scores per model+tier sorted by composite),
    /api/benchmark/run (Quick mode triggers webhook, Deep mode points at
    stream URL), /api/benchmark/stream (Server-Sent Events streaming
    stdout from `docker exec homeai-model-evaluator python -u
    /app/run_benchmark.py …`). Dashboard container now ships the docker
    static binary at /usr/local/bin/docker + mounts /var/run/docker.sock.
  Dashboard frontend: three new sections —
    1. Compute Distribution: split bar (emerald local · slate cloud) +
       Sovereignty Score tile + £ saved estimate + MTD cloud spend.
    2. Performance Tuning Station: model+tier dropdowns, Quick sweep +
       Deep bench buttons, leaderboard table (mono fonts) with gold-bordered
       leader, static "claude-haiku-4-5" baseline row, freshness amber when
       benchmarks > 7d old, live SSE log pane during deep runs.
    3. Stress pulse on GPU/Agents card while benchmark active.
  Closed loop verified: /api/benchmark/run quick → benchmark_results
    populated (12 rows now), SSE stream emits each line of run_benchmark.py
    output in real time. Sovereignty 100% (9/9 calls local — Anthropic
    not yet called).
  benchmark_tasks.py + run_benchmark.py shipped — comprehensive 28-task
    suite (10 emails + 10 JSON-validity + 5 invoices + 3 reports + speed
    prompts). qwen2.5:7b first run: 65% email accuracy / 30% JSON validity
    / 53.6% invoice / 27.4% reports / 70.9 t/s → 63.6% composite.
    Existing model-evaluator service's simpler 6-task runner: 100% (its
    fixtures are too easy — see SP3-A2 task entry for context).

5-Tier Lifecycle (2026-05-09 ~02:30):
  V18 model_usage_history table — tracks BOTH 'build' (Claude Code in this
    session) AND 'production' (n8n pipelines) AND 'migration' (model swaps)
    in one observability stream. Backfilled 9 production rows from
    audit_log heuristic. New static_context.model.tiers_v2 records the
    canonical 5-tier hierarchy:
      apex          → claude-opus-4-7 (multi-file code surgery)
      legacy_apex   → claude-opus-4-6 (long-context dreaming)
      local_logic   → phi4:14b        (complex JSON / private docs)
      cloud_speed   → claude-haiku-4-5 (fast triage / API glue)
      local_fast    → qwen2.5:7b      (log parsing / hot summaries)
  scripts/log-build-activity.sh — Claude Code calls this from Bash to record
    'build' layer rows (model, summary, tokens, derived tier + cost).
    Smoke test: 3 build entries logged this session at £0.225 total cost.
  Dashboard backend: 2 new endpoints — /api/lifecycle (by_layer + tiers
    rollup + migration log + recent activity) and /api/tiers (5-tier roll
    cross-referenced with MTD activity).
  Dashboard frontend: 3 new sections —
    Intelligence activity (Build vs Production split with per-model
    breakdown + cost/calls); 5-Tier Hierarchy list (each tier with model,
    provider chip, use_for description, MTD calls, +£ saved for local /
    -£ spent for cloud); Migration Log (50 most recent build/production/
    migration rows in scrollable stream with context_layer chip).
  Closed loop verified end-to-end:
    - Build task logged: "added /api/lifecycle endpoint" → appears in build
      layer with claude-opus-4-7 / apex tier.
    - Production task: direct Ollama call to qwen2.5:7b for a reasoning
      puzzle → logged as production / local_fast / qwen2.5:7b → appears in
      Intelligence activity production column.
  phi4:14b pull in flight (had to attach ollama to ai-egress network for
    DNS to registry.ollama.ai).
  phi4:14b benchmark RESULT (Threadripper P620 + RTX 3060 12GB):
    - Email accuracy 50% (qwen 65%)
    - JSON validity 20%   (qwen 30%)
    - Invoice extraction 50.9% (qwen 53.6%)
    - Report parsing   18.5% (qwen 27.4%)
    - Speed 22.8 t/s — below the 30 t/s medium-tier target (76% of target)
    - Composite 49.2% — WORSE than qwen2.5:7b's 63.6%
    Conclusion: keeping qwen2.5:7b as the hot tier model AND treating phi4
    as "available but not auto-promoted to medium" was the right call. The
    medium tier slot stays unfilled until either phi4 prompting is tuned
    (the JSON-validity gap suggests phi4 needs `format: json` in the
    Ollama options) or a different medium-tier candidate is benchmarked
    (qwen3:14b is a candidate). Logged as migration entry id=14.

Selftest 52/52 PASS — final run after lifecycle work.
10 active services: postgres, redis, postgres-exporter, n8n, vault, ollama, llm-router,
  model-evaluator, pdfplumber, prometheus, alertmanager, grafana, netdata, qdrant, metabase,
  open-webui, caddy, build-dashboard (NEW 2026-05-09).
Build dashboard: `services/build-dashboard/` FastAPI + single-page HTML with Tailwind/Alpine/
  Chart.js. Live at `http://100.104.82.53:8090/`. Pulls from postgres + Prometheus + reads
  `data/{phase1,debt,tasks}.yaml` for hand-curated content. Endpoints: /api/snapshot, /api/spend,
  /api/recent, /api/healthz. Phase 1 = 89% (24 done / 27 actionable; 7 blocked-on-user).
  Edit data/*.yaml in-place and the next snapshot picks it up (10s cache).
Step 11 (2026-05-08): Gmail OAuth set up for personal1 (`secret/gmail/personal1`). Real email
  `19e0854873034c7f` ("Re: Swirl website" from hello@sandersdesign.com) flowed end-to-end:
  Gmail poller (QMKzaCFrKBS4ewWm) → email.received event → Master Router routed → gmail-ingest-v1
  webhook → classified → INSERT emails → email.classified event + audit_log. Gate B Q1-Q8 all
  PASS. Q7 closed late on 2026-05-08: Metabase admin password set via reset-password CLI + API
  flow (set-metabase-admin-password.sh — pgcrypto bcrypt is incompatible with Metabase's jBCrypt),
  Email Review Queue card created from /home_ai/.claude/metabase/email-review-queue.md.
  V9 migration applied: `ALTER ROLE homeai_readonly IN DATABASE homeai SET app.current_entity =
  'all'` so RLS lets the Metabase analytics role see across entities.
Today's bug fixes layered to get here:
  - V8 migration (claim_event_batch + recover_stale_leases SECURITY DEFINER funcs)
  - Master Router IF + Switch + workflow_history sync
  - n8n vault-token-header policy snapshot refresh (refresh-n8n-vault-token.sh)
  - Gmail poller URL secret/gmail/account1 → personal1
  - workflow_history sync after activation (recurring n8n gotcha)
  - gmail-ingest-v1 Normalise Payload flatten — was leaving real Gmail data nested under
    .payload while downstream nodes looked at top level (using events.id as gmail_message_id)
Outstanding for full Phase 1 close:
  - personal2 + workspace Gmail OAuth (extends ingest to all 3 accounts; not gating)
  - Pipelines 2-13 (Step 13+ in SPEC) — Milestone C work
  - Phase 1 hardening: model evaluator benchmarks, Authelia, Vault auto-unseal
Gate A: passed.
Step 10: Master Router workflow id is `test-master-router`. Switch v3 fix (rules.values, no
  fallbackOutput enum bug) and System Active? IF fix (compares `$json.state` to `'running'` after
  Kill Switch query extracts `value->>'state'` as text) both applied to BOTH workflow_entity (draft)
  and workflow_history (active version). Source `master-router.fixed.json` patched.
Migrations applied: V2 metabase_db, V3 restore_rls_policies, V4 drop_static_context_trigger,
  V5 fix_rls_policy_expression, V6 ai_usage, V7 rent_payments_entity_id, V8 master_router_functions,
  V9 metabase_readonly_entity_all, V10 ensure_next_event_partition, V11 import_bank_transactions,
  V12 partition_target_two_months, V13 cleanup_dead_letter_and_fix_stale_recovery,
  V14 stale_lease_audit_log, V15 system_alerts.
Pipeline 11 (Partition Maintenance, id `partition-maintenance-v1`): scheduleTrigger cron
  `0 9 25 * *` → Vault signing key fetch → `SELECT * FROM ensure_next_event_partition()` →
  HMAC-sign canonical payload → INSERT events (event_type='partition.ensured') + audit_log via
  WHERE NOT EXISTS pattern. Active. SQL path verified via two-statement transaction dry-run.
  Full e2e (cron + Vault HTTP + Code + Postgres) first fires 2026-06-25 09:00.
gmail-ingest-v1 patch (2026-05-08): all three events INSERTs (`email.received`, `email.classified`,
  `invoice.detected`) now use `WHERE NOT EXISTS (SELECT 1 FROM events WHERE idempotency_key = ...)`
  for application-level dedup. Replaces no-idempotency VALUES INSERTs that previously relied solely
  on the upstream Idempotency Check + n8n single-worker-no-retry default. Canonical export at
  `/home_ai/.claude/n8n-exports/gmail-ingest.json`. Patched via `/tmp/patch-gi-idem.py`.
Email Pipeline (id email-pipeline-v1) imported and active. Vault signing-key fetch node mirrors
  Gmail Ingest pattern.
Sprint 2026-05-08 status: items 2-5 done; item 1 (synthetic email test) BLOCKED on
  n8n Postgres-node executeQuery dropping RETURNING rows when set_config is involved. Three
  candidate fixes documented in OVERNIGHT-LOG (SECURITY DEFINER function, BYPASSRLS role,
  or split into two Postgres nodes). Items 6-7 deferred for next session.
Next: resolve Master Router routing (Item 1 unblocker) before Step 11. Gmail OAuth still
  user-side. Email Review Queue Metabase card SQL ready in
  `/home_ai/.claude/metabase/email-review-queue.md` for 2-min UI paste.
