# Step 9b — Model Stack Evaluator: Bring-up & Verify

## Context

Step 9b of the Home AI build (Phase 1, Milestone A). The Model Stack Evaluator is a FastAPI service that:
- scans Ollama for installed models and writes `model_registry`
- runs benchmarks against fixture tasks per tier, writing `benchmark_results` and `model_scores`
- assigns models to tiers (`hot`/`medium`/`heavy`) via `static_context.model.tiers`, which all pipelines read at runtime

Code, schema, compose wiring, and Vault pattern are **already in place**. The container is currently in a restart loop because it was rebuilt in a shell where the Vault-sourced DB password was not exported, so `POSTGRES_PASSWORD` resolved to empty string in compose substitution, and asyncpg fails with `InvalidPasswordError: password authentication failed for user "homeai_pipeline"`.

This plan is therefore an **operational bring-up + verification**, not a code change. No files in `/home_ai/` are modified.

## What was investigated (read-only)

- `/home_ai/services/model-evaluator/main.py` — FastAPI on `:8008`, lifespan opens an asyncpg pool from `POSTGRES_*` env vars, talks to Ollama at `OLLAMA_HOST`. Endpoints: `/healthcheck`, `POST /api/scan`, `GET /api/models`, `POST /api/models/{name}/deploy/{tier}`, `POST /webhook/model-evaluator-manual`. Sets `SET LOCAL app.current_entity = 'all'` in every transaction (defensive — tables aren't RLS-enabled but the sentinel is accepted).
- `/home_ai/services/model-evaluator/Dockerfile` — `python:3.11-slim`, uvicorn on `0.0.0.0:8008`. Fine.
- `/home_ai/docker-compose.yml` (lines 204–219) — service wired to `ai-internal`, port `8008:8008`, env reads `${N8N_DB_PASSWORD}` (homeai_pipeline role), `depends_on` postgres healthy + ollama started.
- `/home_ai/postgres/init-db.sql` — `model_registry`, `benchmark_results`, `model_scores` (UNIQUE on `(model_name, tier, score_date)` matches the `ON CONFLICT` clause), `model_scan_log`, `static_context` all present.
- `/home_ai/postgres/rls-policies.sql` — model tables not under RLS (cross-entity reference data); `'all'` accepted as sentinel.
- `/home_ai/start.sh` — fetches `secret/postgres-roles.homeai_pipeline` from Vault, exports `N8N_DB_PASSWORD`, runs `docker compose up -d`. Has `trap cleanup_secrets EXIT` which unsets the var on exit — this is by design and is the reason a separate shell can't see the value.
- `/home_ai/config/caddy/Caddyfile` — port `8080` is **Caddy → open-webui**, not model-evaluator. SPEC's `curl http://localhost:8080/...` for Step 9b is a typo; correct port is `8008`.
- `docker logs homeai-model-evaluator` — confirms `InvalidPasswordError`. `docker inspect` shows `POSTGRES_PASSWORD=` (empty).

## Plan

### 1. Restart the service through `start.sh` to repopulate env from Vault

`./start.sh` is the canonical bring-up path. It will:
- find Vault already unsealed (no-op)
- prompt for the Vault root token (interactive — Jo's action)
- fetch `secret/postgres-roles.homeai_pipeline` and export `N8N_DB_PASSWORD`
- run `docker compose up -d` — compose detects the env change (`POSTGRES_PASSWORD` was `""`, now real) and recreates only `model-evaluator`. All other healthy containers untouched.

If compose does *not* recreate automatically because it tracks compose-file env not container env: fall back to `docker compose up -d --force-recreate model-evaluator` (run inside the same shell after start.sh exports the var — i.e. add the recreate as a follow-up command before start.sh's `EXIT` trap fires; or re-run start.sh's `fetch_secrets` logic in current shell).

**Cleanest invocation**: just run `./start.sh` from `/home_ai/`. No compose-file edits, no env wrappers, no `--build` (image is already built and correct).

### 2. Verify the container is healthy

- `docker ps --filter name=homeai-model-evaluator --format '{{.Status}}'` → `Up <n> seconds` (no `Restarting`)
- `docker logs --tail 20 homeai-model-evaluator` → clean uvicorn startup, no asyncpg errors
- `curl -fsS http://localhost:8008/healthcheck` → `{"status":"ok"}`

### 3. Scan installed models

```bash
curl -fsS -X POST http://localhost:8008/api/scan | jq
```

Expected: `qwen2.5:7b` in `new_models` (first scan) or `updated_models` (subsequent). Verify in DB:

```bash
docker exec homeai-postgres psql -U postgres -d homeai -c \
  "SELECT model_name, installed, ollama_digest IS NOT NULL AS has_digest, last_seen_in_registry FROM model_registry ORDER BY model_name;"
docker exec homeai-postgres psql -U postgres -d homeai -c \
  "SELECT scan_id, models_found, new_models, updated_models, scan_source, scanned_at FROM model_scan_log ORDER BY scanned_at DESC LIMIT 1;"
```

### 4. Deploy `qwen2.5:7b` to the hot tier (the SPEC step)

SPEC says port 8080 — that's a typo. Real call:

```bash
curl -fsS -X POST 'http://localhost:8008/api/models/qwen2.5%3A7b/deploy/hot' | jq
```

Expected: `{"status":"deployed","model":"qwen2.5:7b","tier":"hot"}`. Verify:

```bash
docker exec homeai-postgres psql -U postgres -d homeai -c \
  "SELECT model_name, deployed_tier FROM model_registry WHERE deployed_tier IS NOT NULL;"
docker exec homeai-postgres psql -U postgres -d homeai -c \
  "SELECT key, value FROM static_context WHERE key = 'model.tiers';"
```

Should show `qwen2.5:7b` as `hot` and `static_context.model.tiers` containing `{"hot":"qwen2.5:7b"}`.

### 5. Optional sanity: run the manual benchmark webhook

Not strictly required by the SPEC for Step 9b, but proves the benchmark path works end-to-end before Milestone B starts using `model.tiers`:

```bash
curl -fsS -X POST http://localhost:8008/webhook/model-evaluator-manual --max-time 600 | jq '.benchmark | {model, tier, task_count, passed, composite_score, accuracy_score, avg_speed_tps}'
```

Expected: `task_count: 6`, non-zero `composite_score`, `avg_speed_tps` in the 60–90 range on the RTX 3060.

If this is too slow or noisy for now, skip — manual benchmarking is a Phase 2 hardening item (per SPEC line 1938), and the deploy in Step 4 is what the SPEC actually requires for Step 9b.

## Critical files (referenced, not modified)

- `/home_ai/start.sh` — bring-up entrypoint (line 121: `N8N_DB_PASSWORD` export)
- `/home_ai/docker-compose.yml` (lines 204–219) — model-evaluator service block
- `/home_ai/services/model-evaluator/main.py` — service code (no edit needed)
- `/home_ai/postgres/init-db.sql` (lines 109–114, 556–633) — schema
- `/home_ai/SPEC.md` (line 1804) — step definition; port `8080` is a typo (use `8008`)

## Risks / open questions

- **start.sh recreate scope**: `docker compose up -d` may recreate only `model-evaluator` (env changed) or may do a no-op for already-healthy services. If it tries to recreate things like `n8n` or `postgres`, that's fine — they're idempotent and the env passed in is correct. Only watch for unexpected restarts in the post-run `docker compose ps`.
- **SPEC typo**: do not edit `SPEC.md` as part of this step unless Jo asks. Note it in the post-run summary so it can be fixed deliberately.
- **Build feedback rule**: `/simplify` and `/review` should run before marking a step done. Since this step makes **no code changes**, there is nothing for those commands to review beyond the existing `main.py`. I'll only run them if Jo requests, or if Step 4 surfaces a code defect.

## Done criteria

1. `homeai-model-evaluator` is `Up`, not restarting.
2. `model_registry` row exists for `qwen2.5:7b` with `installed = true`, `deployed_tier = 'hot'`.
3. `static_context.model.tiers = {"hot":"qwen2.5:7b"}`.
4. `model_scan_log` has at least one row with `scan_source = 'ollama_local'`.
5. `events_overflow: COUNT(*) = 0` still holds (this step writes no events; check is a regression guard).
