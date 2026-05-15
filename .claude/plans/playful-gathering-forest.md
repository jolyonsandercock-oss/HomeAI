# Plan: Step 9b Fix & Milestone B Entry

## Context

Step 9b (Model Stack Evaluator) is partially complete — the container has been running for 26 hours, but it was built from **stale code**. The on-disk `main.py` was updated in a previous session to add HMAC-signed event emission (the mandatory rule from `feedback_homeai.md`), but the container was never rebuilt. The old container code works for the deploy operation, but doesn't emit the required `system.config_change` event.

**Current DB state (correct):**
- `model_registry`: qwen2.5:7b installed, deployed_tier = hot
- `static_context.model.tiers`: `{"hot": "qwen2.5:7b", "heavy": "llama3.3:70b", "medium": "phi4:14b"}`

**Current container state (stale):**
- Running old code without HMAC imports, `sign_payload()`, or events INSERT
- The original `InsufficientPrivilegeError` from logs was a red herring from an even older code version — asyncpg INSERT into events has been tested and works correctly

## Fix: Rebuild and verify

### Step 1 — Rebuild the container

```bash
cd /home_ai
docker compose up -d --build model-evaluator
```

### Step 2 — Verify healthcheck

```bash
curl -s http://localhost:8008/healthcheck
# Expected: {"status": "ok"}
```

### Step 3 — Call the deploy endpoint (Step 9b acceptance test)

```bash
curl -s -X POST "http://localhost:8008/api/models/qwen2.5%3A7b/deploy/hot"
# Expected: {"status": "deployed", "model": "qwen2.5:7b", "tier": "hot"}
```

### Step 4 — Verify event was emitted with HMAC

```bash
docker exec homeai-postgres psql -U homeai_pipeline -d homeai \
  -c "SELECT event_type, source, payload_signature IS NOT NULL as signed, created_at FROM events WHERE event_type = 'system.config_change' ORDER BY created_at DESC LIMIT 3;"
```

Expected: row with `event_type=system.config_change`, `signed=t`

### Step 5 — Verify model tiers in static_context

```bash
docker exec homeai-postgres psql -U homeai_pipeline -d homeai \
  -c "SELECT value FROM static_context WHERE key = 'model.tiers';"
```

Expected: `{"hot": "qwen2.5:7b", ...}`

## Critical files

- `/home_ai/services/model-evaluator/main.py` — has the correct disk code, just needs rebuild
- `/home_ai/docker-compose.yml` — build config, no changes needed

## After 9b acceptance

Step 9b gate passes → move to **Milestone B**:
- Step 10: Configure n8n Master Router
- Step 11: Gmail Ingest vertical slice  
- Step 12: Minimal Metabase
- Gate B: 8 checks

## What NOT to do

- Do not re-run /api/scan before deploy (model_registry already correct)
- Do not manually set static_context again (already correct)
- Medium/heavy model tiers (phi4:14b, llama3.3:70b) stay in static_context as placeholders — actual pull is Step 13 (Milestone C), not now
