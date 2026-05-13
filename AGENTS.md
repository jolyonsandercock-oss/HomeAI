# Home AI Administrative Engine — AGENTS.md
# Portable across coding tools. Tight rule set, not state.

## Read first, every session

1. **`/home_ai/STATUS.md`** — current build state (human-readable mirror of memory).
2. **This file (AGENTS.md)** — operational rules + non-negotiables.
3. **Auto-memory** at `/home/joly/.claude/projects/-home-joly/memory/` — canonical state store, auto-loaded by harness. Read individual `feedback_*.md` files when their topic comes up.
4. **`/home_ai/SPEC.md`** — architectural reference. Read only the relevant section for the current step, never end-to-end.

`HOME-AI-STRETCH.md` is future-ideas only — read on demand.

## Session opening prompt

> "Read STATUS.md and AGENTS.md. Run state sync (3 commands). We are on [phase/step]. Proceed."

## State sync (3 commands at session start)

```bash
docker ps --format '{{.Names}}\t{{.Status}}' | grep homeai- | wc -l        # expect ~24
ls /home_ai/postgres/migrations/ | sort -V | tail -3                        # latest migration
docker exec homeai-postgres psql -U postgres -d homeai \
  -c "SELECT id, raw_subject FROM bot_instructions WHERE status='pending';"
```

## System identity

- **Owner**: Jo Sandercock
- **Entities**: 1=ARTL (pub/inn/restaurant/ice-cream — Malthouse Tintagel), 2=AREL (7 investment properties), 3=Personal, 4=Family (3 kids)
- **Host**: JolyBox, Ubuntu 26.04, kernel 7.0.x, Tailscale-fenced (100.104.82.53)
- **~24 docker containers** under one compose file at `/home_ai/docker-compose.yml`

## Source-of-truth systems (never override)

Xero=accounting | Dext=manual invoice review only (no API — see `feedback_dext`) | Bank=transactions | TouchOffice/ICRTouch=EPOS | Caterbook=accommodation | Tanda=workforce

## Architecture rules (non-negotiable, hook-enforced where possible)

1. **NEVER write secrets to files.** Vault only. No `.env`, no hardcoded values, no n8n credential-store secrets.
2. **NEVER `docker compose up` directly.** Always `./start.sh` — handles Vault unseal + secret injection.
3. **ALWAYS `SET LOCAL app.current_entity`** before any Postgres write (RLS).
4. **ALWAYS sanitise external content** via `body_text_safe` before AI prompts (injection guard).
5. **ALWAYS sign event payloads** (HMAC-SHA256) before INSERT to `events`.
6. **ALWAYS check `idempotency_key`** before processing — every pipeline must be re-run safe.
7. **`events.idempotency_key` has NO unique constraint** — use `WHERE NOT EXISTS`, never `ON CONFLICT`.
8. **n8n stores 2 copies of workflows** — `workflow_entity.nodes` is draft, `workflow_history` (active versionId) is what runs. Patch the right one.
9. **JSONB → IF nodes**: coerce to text in SQL with `->>`, or strict-type checks fail with "object expecting string".
10. **Third-party password hashing** (Metabase, Grafana, Authelia): use the tool's own CLI/API, never INSERT/UPDATE the user table directly.
11. **Holiday entitlement**: statutory pro-rata only. Never 12.07%.
12. **After `secret/postgres-roles` rotation**: run `sync-n8n-postgres-credential.sh` to refresh n8n's stored credential.
13. **Run `/simplify` then `/review`** before marking any step complete.

## Environment facts (real, not spec assumptions)

- Postgres 16.13 (upgraded from 15)
- Vault hashicorp/vault:1.15.6 — stale, flagged for in-person update
- All images pinned (no `:latest` tags)
- PreToolUse hooks installed at `~/.claude/settings.json`
- Selftest at `/home_ai/scripts/selftest.sh` — expect 51/52 PASS (Gmail Ingest workflow `QMKzaCFrKBS4ewWm` is pre-existing FAIL; not blocking)
- Model evaluator on port **8008** (not 8080; conflict with Open WebUI)

## Model stack (verified 2026-05-13 from `model_inventory_log`)

| Tier | Model | Size | Use |
|---|---|---|---|
| Hot (T1) | qwen2.5:7b | 4.36 GB | email classification, hot summaries (see `project_qwen_u7_optimisation`) |
| Medium (T2) | phi4:14b | 8.43 GB | complex JSON, private docs |
| Heavy (T3) | — | — | not currently loaded (llama3.3:70b was removed) |
| Cloud (escalation) | claude-haiku-4-5 | — | invoice extraction, classifier fallback |
| Cloud (reasoning) | claude-sonnet-4-6 | — | dreaming, reconciliation, hospitality drafting |
| Cloud (apex) | claude-opus-4-7 | — | high-stakes code surgery, this session |

Hot tier optimisation: see memory `project_qwen_u7_optimisation.md` (95.7% composite via prompt engineering).

## Global kill switch

```sql
SELECT value FROM static_context WHERE key='system.state';
```

If `'paused'`: stop, log, don't process. Pause/resume only via `/pause-all` and `/resume-all` slash commands.

## Pipeline rules

- Master Router reads `/home_ai/storage/dreaming/heuristics.md` (capped 2KB) at start-of-batch and prepends to AI worker system prompts.
- AI worker output must follow OutcomeObject pattern: `{status, confidence, reasoning, data, requires_human, worker, tier_used}`.
- From U38 onwards: use **JSON Schema constrained generation** (Ollama `format`, Anthropic tool-use with `input_schema`) — never "prompt says return JSON". See SPEC §7.3.
- Confidence threshold (per worker, in `static_context`): `min_confidence` triggers escalation to higher tier; escalate band = `confidence ≥ threshold × 0.85`.

## Working discipline

Full rules in `feedback_working_discipline.md`. Summary:

1. Verify before claiming done — smoke-test in the running system.
2. Don't write CLI invocations you haven't seen succeed. `--help` first.
3. State sync at session start (above).
4. No A/B menus mid-execution — pick one path, document trade-off in a sentence.
5. Scripts with prompts beat long copy-paste — for any secret/multi-line/special-char step.
6. Break iteration loops after 3 attempts — restore stable state, document, hand off.
7. Audit ALL consumers before replacing a producer.

## Slash commands

Most-used: `/simplify`, `/review`, `/retro`, `/ultrareview`, `/compact`, `/init`, `/pause-all`, `/resume-all`, `/schedule`.

## Subagent model routing

For focused subagent tasks: `export CLAUDE_CODE_SUBAGENT_MODEL="claude-haiku-4-5-20251001"`. Main session for complex reasoning: default (Sonnet or Opus).

## Context management

- Watch indicator. Run `/compact` before 60% capacity.
- Never let auto-compaction fire during Vault, DB, or Docker steps — it's lossy at critical moments.

## Pre-push entropy scan (MANDATORY before `git push`)

See `feedback_homeai_pre_push_scan.md`. Filename-based gitignore misses bootstrap-written hex secrets in YAML configs. Always entropy-scan the staged tree:

```bash
git diff --staged --name-only | xargs -I{} sh -c 'grep -EH "([a-f0-9]{32,}|hvs\.[a-zA-Z0-9]{20,}|sk-[a-zA-Z0-9-]{30,}|ghp_[a-zA-Z0-9]{30,}|argon2id)" "{}" 2>/dev/null || true'
```

Any hits → STOP. Show user before commit. Common false positives: AGENTS.md/SPEC.md mentioning hash schemes.

## Key paths

```
Status:      /home_ai/STATUS.md             ← current build state (human mirror)
Spec:        /home_ai/SPEC.md               ← architectural reference
Stretch:     /home_ai/HOME-AI-STRETCH.md    ← future ideas only
Memory:      /home/joly/.claude/projects/-home-joly/memory/
Sprints:     /home_ai/.claude/sprints/U*.md
Migrations:  /home_ai/postgres/migrations/V*.sql (latest = V43)
Compose:     /home_ai/docker-compose.yml
Startup:     /home_ai/start.sh              ← run after every reboot
Schema:      /home_ai/postgres/init-db.sql + rls-policies.sql
Services:    /home_ai/services/
Skills:      /home_ai/.claude/skills/
Commands:    /home_ai/.claude/commands/
n8n exports: /home_ai/.claude/n8n-exports/
AI schemas:  /home_ai/ai_schemas/           ← per-worker JSON Schemas (U38+)
```

## Gotchas — pointers to memory

These are documented in `/home/joly/.claude/projects/-home-joly/memory/`. The harness auto-loads MEMORY.md; the per-topic files load when their content becomes relevant. One-line summary each:

- `feedback_n8n_gotchas` — multi-trigger breaks cron, ai-internal is `internal:true`, Open WebUI WEBUI_SECRET_KEY must be Fernet, inline-array port specs misparse
- `feedback_caterbook_revenue` — `revenue_in_house` is outstanding balance (double-counts); use `caterbook_room_nights` for daily revenue
- `feedback_telegram_heartbeat` — `u29-heartbeat` is quiet-unless-degraded; all sends log to `telegram_outbox`
- `feedback_bot_self_loop_guard` — Gmail thread re-parsing made bot's own replies look like new instructions; `u29-instructions-poll` skips them
- `feedback_pdfplumber_service` — port 8003 (not 8000), `/extract-pdf` (not `/extract`), `/healthcheck` (not `/healthz`), use `homeai-pdfplumber` (container name) for DNS
- `feedback_authelia_cookie_domain` — Authelia running at `/auth/` but forward_auth on protected routes needs tailscale-cert FQDN for cookies to work
- `feedback_dashboard_image_rebuild` — `main.py` + `static/` are baked into the image; rebuild + harvest POSTGRES_PASSWORD before `compose up`
- `feedback_bot_instructions_check` — surface pending `bot_instructions` rows at session start

## Build state

See **STATUS.md** for current phase/step/sprint. AGENTS.md does not track state — that's what STATUS.md is for.
