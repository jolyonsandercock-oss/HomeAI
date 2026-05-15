# Plan: llm-router service — model routing + escalation wrapper

## Context

Jo wants to stop burning Claude API tokens on routine tasks (email classification, invoice extraction, memory lookups) that local Ollama models can handle for free. The stack already has Ollama with qwen2.5:7b (hot tier), and the model-evaluator service already manages tier assignments in `static_context`. This plan builds `llm-router` — a FastAPI microservice that n8n calls instead of hitting Ollama or Claude directly. It routes to the right local model, escalates to Claude when confidence is low, caches frequent results in Redis, and logs every decision so token spend is visible in Metabase/Grafana.

---

## What we're building

**1 new service:** `llm-router` on port 8001  
**1 new migration:** `V3__ai_usage.sql`  
**Changes to:** `docker-compose.yml`, `start.sh`  

---

## Files to create / modify

| File | Action |
|---|---|
| `/home_ai/services/llm-router/main.py` | Create |
| `/home_ai/services/llm-router/Dockerfile` | Create |
| `/home_ai/services/llm-router/requirements.txt` | Create |
| `/home_ai/postgres/migrations/V3__ai_usage.sql` | Create |
| `/home_ai/docker-compose.yml` | Edit — add llm-router service |
| `/home_ai/start.sh` | Edit — fetch + export ANTHROPIC_API_KEY |

---

## Step 1 — Migration: `ai_usage` table

**File:** `/home_ai/postgres/migrations/V3__ai_usage.sql`

```sql
CREATE TABLE IF NOT EXISTS ai_usage (
  id               BIGSERIAL PRIMARY KEY,
  timestamp        TIMESTAMPTZ DEFAULT NOW(),
  trace_id         UUID,
  entity_id        INT REFERENCES entities(id),
  task_type        TEXT NOT NULL,
  model_used       TEXT NOT NULL,
  tier             TEXT NOT NULL,
  escalated        BOOLEAN DEFAULT FALSE,
  escalation_reason TEXT,
  prompt_tokens    INT DEFAULT 0,
  completion_tokens INT DEFAULT 0,
  latency_ms       INT DEFAULT 0,
  cached           BOOLEAN DEFAULT FALSE
);
CREATE INDEX idx_ai_usage_task_type ON ai_usage (task_type, timestamp DESC);
CREATE INDEX idx_ai_usage_escalated ON ai_usage (escalated, timestamp DESC);
```

Must run before service starts. Apply with:
```bash
docker exec -i homeai-postgres psql -U homeai_pipeline -d homeai < /home_ai/postgres/migrations/V3__ai_usage.sql
```

---

## Step 2 — requirements.txt

```
fastapi==0.111.0
uvicorn==0.30.0
httpx==0.27.0
asyncpg==0.29.0
redis[asyncio]==5.0.4
```

---

## Step 3 — Dockerfile

Same pattern as model-evaluator:
```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001"]
```

---

## Step 4 — main.py (full service)

### Routing table (task_type → tier)
Populated from `static_context model.tiers` at startup, with hardcoded fallback:
```python
TASK_TIER_DEFAULT = {
    "email.classify":        "hot",
    "email.route":           "hot",
    "child.classify":        "hot",
    "invoice.extract":       "medium",
    "report.parse":          "medium",
    "bank.categorise":       "medium",
    "digest.generate":       "heavy",
    "reconciliation.reason": "heavy",
}
CLAUDE_DIRECT = {
    "legal.analyse":         "claude-sonnet-4-6",
    "cashflow.analyse":      "claude-sonnet-4-6",
    "compliance.check":      "claude-opus-4-7",
}
```

### Request / Response schemas
```python
class RouteRequest(BaseModel):
    task_type: str
    prompt: str
    entity_id: int | None = None
    allow_escalation: bool = True
    trace_id: str | None = None

class RouteResponse(BaseModel):
    text: str
    model_used: str
    tier: str
    escalated: bool
    escalation_reason: str | None
    latency_ms: int
    prompt_tokens: int
    completion_tokens: int
    cached: bool
    trace_id: str
```

### Core routing logic (POST /route)
1. Check Redis cache: key = `llm_router:{task_type}:{sha256(prompt[:300])}`, TTL=3600
2. If task_type is in `CLAUDE_DIRECT` → skip Ollama, go direct to Claude
3. Look up tier for task_type → look up model name from `static_context model.tiers`
4. Call Ollama `POST /api/generate` with 60s timeout
5. Try JSON parse on response — if structured task and parse fails → flag for escalation
6. Check confidence: if response has `confidence_score` field and it's below threshold from `static_context ai.thresholds` → flag for escalation
7. If escalation flagged and `allow_escalation=True` → call Claude Haiku (`claude-haiku-4-5-20251001`)
8. Log to `ai_usage` table (fire-and-forget, do not block response)
9. Cache if not escalated and task_type is hot tier
10. Return `RouteResponse`

### Escalation — Claude call
Uses `httpx.AsyncClient`, Anthropic messages API:
```python
response = await http.post(
    "https://api.anthropic.com/v1/messages",
    headers={
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
    },
    json={
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 1024,
        "messages": [{"role": "user", "content": prompt}],
    },
    timeout=30.0,
)
```

### Additional endpoints
- `GET /healthcheck` → `{"status": "ok"}`
- `GET /stats` → last 24h: local vs escalated counts, token spend estimate

### Error handling
- Ollama timeout / 5xx → escalate if `allow_escalation`, else return error
- Claude failure → return 502 with detail
- DB log failure → warn + continue (do not fail the response)

---

## Step 5 — docker-compose.yml addition

Add after `model-evaluator` service:
```yaml
  llm-router:
    build: ./services/llm-router
    container_name: homeai-llm-router
    networks: [ai-internal]
    environment:
      OLLAMA_HOST: "http://ollama:11434"
      ANTHROPIC_API_KEY: "${ANTHROPIC_API_KEY}"
      REDIS_HOST: "redis"
      REDIS_PASSWORD: "${REDIS_PASSWORD}"
      POSTGRES_HOST: "postgres"
      POSTGRES_PORT: "5432"
      POSTGRES_USER: "homeai_pipeline"
      POSTGRES_PASSWORD: "${N8N_DB_PASSWORD}"
      POSTGRES_DB: "homeai"
      PAYLOAD_HMAC_KEY: "${PAYLOAD_HMAC_KEY}"
    depends_on:
      postgres: {condition: service_healthy}
      ollama:   {condition: service_started}
      redis:    {condition: service_started}
    ports: ["8001:8001"]
    restart: unless-stopped
```

---

## Step 6 — start.sh changes

In `fetch_secrets()`, add one line after existing fetches:
```bash
ANTHROPIC_API_KEY=$(vault_kv_field secret/anthropic api_key)
```

In `cleanup_secrets()`, add `ANTHROPIC_API_KEY` to the unset list.

In the `export` line, add `ANTHROPIC_API_KEY`.

---

## Step 7 — How n8n uses this

n8n pipelines replace direct Ollama HTTP nodes with:
```
POST http://llm-router:8001/route
{
  "task_type": "email.classify",
  "prompt": "{{ sanitised body_text_safe }}",
  "entity_id": 1,
  "allow_escalation": true,
  "trace_id": "{{ $execution.id }}"
}
```
Response field `text` contains the model output. Field `escalated` tells n8n whether to apply tighter validation. Field `model_used` goes into the DB log.

---

## Verification

After build:
```bash
# 1. Run migration
docker exec -i homeai-postgres psql -U homeai_pipeline -d homeai < /home_ai/postgres/migrations/V3__ai_usage.sql

# 2. Rebuild + start router
docker compose up -d --build llm-router

# 3. Healthcheck
curl http://localhost:8001/healthcheck
# → {"status": "ok"}

# 4. Route a test email (local only)
curl -X POST http://localhost:8001/route \
  -H "Content-Type: application/json" \
  -d '{"task_type":"email.classify","prompt":"From: billing@staustellbrewery.co.uk\nSubject: Invoice INV-204418","entity_id":1,"allow_escalation":false}'
# → {"text":"invoice","model_used":"qwen2.5:7b","tier":"hot","escalated":false,...}

# 5. Check ai_usage table
docker exec homeai-postgres psql -U homeai_pipeline -d homeai \
  -c "SELECT task_type, model_used, escalated, latency_ms FROM ai_usage ORDER BY timestamp DESC LIMIT 5;"

# 6. Stats endpoint
curl http://localhost:8001/stats
```
