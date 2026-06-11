# Hermes Role Build — Design Spec

Date: 2026-06-11
Approved by: Jo (approach B of A/B/C)
Context: Jo is cutting interactive Fable usage for cost. Hermes Agent (Nous, v0.15.x at `~/.hermes/`, Telegram-connected) becomes the daily-driver **home assistant / PA / researcher / homeai task rabbit**. Claude Max is retained for build/fix work; cheap models (DeepSeek, Haiku) carry routine load. A 48GB GPU is on order (not yet installed — box still has RTX 3060 12GB).

## Access decision

**Read + safe operations.** Hermes may read homeai data (read-only Postgres role, homeai-mcp, dashboards) and run an allowlisted set of operational scripts. Anything write-shaped beyond the allowlist becomes a proposal drop in `/home_ai/.hermes/` for Claude Code, or a question to Jo. Business sign-off decisions (pipeline on/off, category changes, money-adjacent writes) are never taken autonomously. Existing protocol stands: **Hermes proposes, Claude verifies, Jo decides.**

Caveat (accepted): Hermes runs as user `joly`, so the allowlist is policy enforcement (approvals + persona + script-internal whitelists), not a hard sandbox. A hard boundary would need a dedicated Unix user — out of scope for v1.

## Components

### 1. Identity
- `~/.hermes/SOUL.md`: UK English; concise, tabled answers; no methodology rambling; four entities (1 ART, 2 ARE, 3 Personal, 4 Family); operating contract above; data-truth rules: de-dup `bank_transactions` before any sum, revenue = `head_office` (site 0) only, café = J&R MAL125 only, source-of-truth beats DB.
- Same data-truth facts appended to `~/.hermes/memories/MEMORY.md`.

### 2. Model routing (3060 era)
| Function | Setting |
|---|---|
| Default | DeepSeek flash via `deepseek` provider (paid key, ~pennies/day) |
| Fallback | Free Nous tier (Hermes-4 + tool gateway; 10 RPM limit) |
| Delegation | DeepSeek flash, max 2 children (was broken: claude-haiku via absent openrouter creds) |
| Escalation | Haiku 4.5 via Anthropic key in credential pool — `/model` switch for hard/financial questions |
| Vision | Local `qwen2.5vl:7b` via Ollama OpenAI endpoint if host-reachable, else auto |

### 3. Researcher
- `web.search_backend: searxng` + `SEARXNG_URL` env, against local SearXNG published to `127.0.0.1:8888` (service sits on non-internal `ai-egress`; JSON format already enabled).
- Firecrawl extraction stays on the free Nous gateway.
- `allow_private_urls: true` (web/browser/security) so Hermes can read its own dashboards on the Tailscale IP.

### 4. Task rabbit
- Postgres role `hermes_ro`: LOGIN, SELECT-only; password in Vault `secret/hermes`; access via `docker exec homeai-postgres psql -U hermes_ro -d homeai` (no new port exposure). RLS behaviour tested explicitly (OR short-circuit + GUC-default traps are known). Realm: owner (sees all realms; Jo is the only Hermes user).
- homeai-mcp (100.104.82.53:8765) wired into Hermes `mcp_servers`.
- `/home_ai/scripts/hermes-safe/`: argument-validated wrappers — `restart-service.sh <name>` (internal whitelist), `rerun-touchoffice-realtime.sh`, `rerun-caterbook-daily.sh`, `rerun-weather.sh`, `health-snapshot.sh`, `show-dead-letters.sh`. Added to Hermes `command_allowlist`; `approvals.mode` stays `manual` for everything else.

### 5. PA layer
- Morning brief cron 07:30 Europe/London → Telegram: weather, today's Caterbook arrivals/occupancy, yesterday's head-office revenue, open system alerts. (Evening email digest already exists in homeai; no duplication.)
- Hygiene: `hermes update`; `timezone: Europe/London`; delete dead 4-eyes one-off cron; cost-tracker cron hourly → 08:00/20:00; memory char limits 2200→3300 / 1375→2000.

### 6. 48GB flip pack
Corrected checklist + config block at `/home_ai/analysis/48gb-flip-checklist.md`, replacing the Hermes drop whose errors are recorded there (3 concurrent 72B children impossible on 48GB; VL-72B swaps with the text model, not coexists; "sub-second" VL invoice extraction unrealistic; Ollama tag is `qwen2.5vl`, not `qwen2.5-vl`).

### 7. Ubuntu box (independent of Hermes)
- Postgres: `shared_buffers 16GB, effective_cache_size 64GB, work_mem 64MB, maintenance_work_mem 2GB, random_page_cost 1.1, wal_compression on` (currently 128MB defaults on 107GB RAM). Requires container restart in a safe window.
- Backups: fix root-owned 0700 file gap; target nightly backup at /mnt/shared_storage (5.5TB, near-empty).
- journald cap 1G; vm.swappiness=10; smartmontools + NVMe health cron → Telegram alert path; weekly dangling-image prune; verify unattended-upgrades.

## Out of scope
litellm budget routing; bot-responder merge; migrating Anthropic API pipelines; dedicated Unix user for Hermes.

## Error handling / verification
- Every config change verified by re-reading effective config or a live probe (search call, MCP tool list, psql SELECT, script dry-run).
- Postgres restart verified by checking dependent containers reconnect and a sentinel query.
- Gateway restarted via drain; Telegram connectivity re-checked.

## Follow-up findings (not in scope, recorded)
- Anthropic platform shows **0% prompt-cache hit rate** ($60/mo spend): API pipelines are paying full price. Known thresholds: Haiku needs ~5K+ tokens to cache, Sonnet ≥1024. Worth a pipeline prompt audit.
