import asyncio
import hashlib
import json
import os
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from typing import Optional

import asyncpg
import httpx
import redis.asyncio as redis
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

import urllib.request

OLLAMA_HOST = os.environ["OLLAMA_HOST"]
REDIS_HOST = os.environ["REDIS_HOST"]
REDIS_PASSWORD = os.environ["REDIS_PASSWORD"]


def _vault_get(path: str) -> dict:
    """Fetch a secret from Vault. Mirrors bot-responder's helper."""
    addr = os.environ.get("VAULT_ADDR", "http://vault:8200")
    token = os.environ.get("VAULT_TOKEN", "")
    req = urllib.request.Request(
        f"{addr}/v1/secret/data/{path}",
        headers={"X-Vault-Token": token},
    )
    return json.loads(urllib.request.urlopen(req, timeout=5).read())["data"]["data"]


def _resolve_anthropic_key() -> str:
    """Resolution order (U140 pilot):
       1. ANTHROPIC_API_KEY_FILE — Vault Agent-rendered file (preferred)
       2. ANTHROPIC_API_KEY env var (legacy fallback)
       3. Direct Vault fetch (last-resort fallback)
    """
    fpath = os.environ.get("ANTHROPIC_API_KEY_FILE", "").strip()
    if fpath and os.path.exists(fpath):
        try:
            with open(fpath) as f:
                key = f.read().strip()
            if key:
                print(f"[llm-router] loaded ANTHROPIC_API_KEY from {fpath}")
                return key
        except Exception as e:
            print(f"[llm-router] WARN: failed to read {fpath}: {e}")
    env = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if env:
        print("[llm-router] loaded ANTHROPIC_API_KEY from env")
        return env
    try:
        key = _vault_get("anthropic")["api_key"]
        print("[llm-router] loaded ANTHROPIC_API_KEY from Vault HTTP")
        return key
    except Exception as e:
        print(f"[llm-router] WARN: could not fetch anthropic key: {e}")
        return ""


ANTHROPIC_API_KEY = _resolve_anthropic_key()

# U141: cloud-bound calls (i.e. any path that hits _call_claude) are
# routed through homeai-presidio for PII redaction first. If the redactor
# is unreachable or errors, this is a HARD FAIL — the Claude call does
# NOT proceed, and the caller gets a 503. No soft pass-through.
# The Telegram bot is exempt: it doesn't use this router at all, it talks
# to anthropic.Anthropic directly. Other conversational/agent loops that
# go through here are NOT exempt.
PRESIDIO_URL = os.environ.get("PRESIDIO_URL", "http://homeai-presidio:8765")
PRESIDIO_REQUIRED = os.environ.get("PRESIDIO_REQUIRED", "1") == "1"

TASK_TIER_DEFAULT = {
    "email.classify": "hot",
    "email.route": "hot",
    "child.classify": "hot",
    "invoice.extract": "medium",
    "invoice.validate": "medium",
    "report.parse": "medium",
    "bank.categorise": "medium",
    "digest.generate": "heavy",
    "reconciliation.reason": "heavy",
}

CLAUDE_DIRECT = {
    "legal.analyse": "claude-sonnet-4-6",
    "cashflow.analyse": "claude-sonnet-4-6",
    "compliance.check": "claude-opus-4-7",
}

DEFAULT_THRESHOLDS = {
    "hot": 0.75,
    "medium": 0.85,
    "heavy": 0.90,
}

# Budget circuit-breaker (Hermes HIGH #4). The per-tier quota ceilings are SHADOW
# (advisory) — nothing blocks a runaway. This is the hard backstop: once today's
# TOTAL spend crosses a high ceiling (well above the £3 soft cap), cloud calls are
# refused so a tight loop / prompt injection can't burn unbounded money. Escalations
# degrade gracefully (keep the free local result); direct cloud tasks get a 429.
# FAIL-CLOSED (Jo, 2026-06-16): any error in the check REFUSES cloud calls. Money
# safety is prioritised over availability — a transient breaker/DB error pauses cloud
# spend (the escalation path keeps the free local result; CLAUDE_DIRECT tasks get a
# 429) rather than leaving an unbounded-spend window open while the breaker is blind.
# Cached ~15s to avoid a query per request.
HARD_DAILY_CAP_GBP = float(os.environ.get("HARD_DAILY_CAP_GBP", "6.0"))
_budget_cache = {"day": None, "spent": 0.0, "at": 0.0}

async def _over_hard_budget(pool) -> bool:
    try:
        import datetime
        now = time.time()
        today = datetime.date.today().isoformat()
        if _budget_cache["day"] == today and (now - _budget_cache["at"]) < 15:
            return _budget_cache["spent"] >= HARD_DAILY_CAP_GBP
        async with pool.acquire() as c:
            spent = await c.fetchval(
                "SELECT coalesce(sum(cost_gbp), 0) FROM ai_usage "
                "WHERE timestamp::date = current_date")
        spent = float(spent or 0.0)
        _budget_cache.update(day=today, spent=spent, at=now)
        return spent >= HARD_DAILY_CAP_GBP
    except Exception as e:
        # FAIL-CLOSED (Jo, 2026-06-16): treat a breaker/DB error as over-budget so a
        # blind breaker can't allow runaway spend. Logged loudly so the bug is visible
        # rather than silently swallowed (the old fail-open path hid breaker bugs).
        print(f"[llm-router] budget breaker error -> failing CLOSED (cloud paused): {e}")
        return True


class RouteRequest(BaseModel):
    task_type: str
    prompt: str
    entity_id: Optional[int] = None
    allow_escalation: bool = True
    trace_id: Optional[str] = None


class RouteResponse(BaseModel):
    model_config = {"protected_namespaces": ()}

    text: str
    model_used: str
    tier: str
    escalated: bool
    escalation_reason: Optional[str] = None
    latency_ms: int
    prompt_tokens: int
    completion_tokens: int
    cached: bool
    trace_id: str


def _cache_key(task_type: str, prompt: str) -> str:
    prompt_hash = hashlib.sha256(prompt[:300].encode()).hexdigest()[:16]
    return f"llm_router:{task_type}:{prompt_hash}"


async def _log_usage(
    pool: asyncpg.Pool,
    trace_id: str,
    entity_id: Optional[int],
    task_type: str,
    model_used: str,
    tier: str,
    escalated: bool,
    escalation_reason: Optional[str],
    prompt_tokens: int,
    completion_tokens: int,
    latency_ms: int,
    cached: bool,
) -> None:
    try:
        async with pool.acquire() as conn:
            await conn.execute(
                """INSERT INTO ai_usage
                   (trace_id, entity_id, task_type, model_used, tier, escalated,
                    escalation_reason, prompt_tokens, completion_tokens,
                    latency_ms, cached)
                 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)""",
                uuid.UUID(trace_id) if trace_id else None,
                entity_id,
                task_type,
                model_used,
                tier,
                escalated,
                escalation_reason,
                prompt_tokens,
                completion_tokens,
                latency_ms,
                cached,
            )
    except Exception as e:
        print(f"Warning: failed to log usage: {e}")


async def _get_model_tiers(pool: asyncpg.Pool) -> dict:
    try:
        async with pool.acquire() as conn:
            value = await conn.fetchval(
                "SELECT value FROM static_context WHERE key = 'model.tiers'"
            )
        return json.loads(value) if value else {}
    except Exception as e:
        print(f"Warning: failed to fetch model.tiers from DB: {e}")
        return {}


async def _get_thresholds(pool: asyncpg.Pool) -> dict:
    try:
        async with pool.acquire() as conn:
            value = await conn.fetchval(
                "SELECT value FROM static_context WHERE key = 'ai.thresholds'"
            )
        return json.loads(value) if value else DEFAULT_THRESHOLDS
    except Exception:
        return DEFAULT_THRESHOLDS


async def _call_ollama(http: httpx.AsyncClient, model: str, prompt: str) -> tuple[str, int, int, int]:
    start_time = time.time()
    try:
        response = await http.post(
            f"{OLLAMA_HOST}/api/generate",
            json={"model": model, "prompt": prompt, "stream": False},
            timeout=60.0,
        )
        response.raise_for_status()
        data = response.json()
        text = data.get("response", "").strip()
        prompt_tokens = data.get("prompt_eval_count", 0) or 0
        completion_tokens = data.get("eval_count", 0) or 0
        latency_ms = int((time.time() - start_time) * 1000)
        return text, prompt_tokens, completion_tokens, latency_ms
    except Exception as e:
        raise HTTPException(502, f"ollama error: {e}")


async def _redact_via_presidio(
    http: httpx.AsyncClient, prompt: str, task_type: str
) -> str:
    """U141: HARD-FAIL redaction gate for cloud-bound calls.

    Returns the redacted prompt on success. Raises HTTPException(503) if
    Presidio is unreachable or returns non-200 — caller MUST NOT then
    proceed to call Claude. The intent is to make it impossible for any
    cloud-bound LLM call to bypass redaction silently.

    On failure we also write a hard_fail row to redaction_audit_log
    ourselves (since Presidio is the normal writer and obviously can't
    write when it's the one being down).
    """
    if not PRESIDIO_REQUIRED:
        return prompt
    try:
        r = await http.post(
            f"{PRESIDIO_URL}/redact",
            json={
                "text": prompt,
                "workflow_id": f"llm-router:{task_type}",
                "capability_tag": task_type,
                "realm": "work",
            },
            timeout=10.0,
        )
        r.raise_for_status()
        return r.json()["redacted_text"]
    except Exception as e:
        # Log the hard-fail event directly from llm-router. Best-effort —
        # if the DB is also down we still want to raise the 503.
        try:
            sha = hashlib.sha256(prompt.encode("utf-8")).hexdigest()
            conn = await asyncpg.connect(
                host=os.environ["POSTGRES_HOST"],
                port=int(os.environ["POSTGRES_PORT"]),
                user=os.environ["POSTGRES_USER"],
                password=os.environ["POSTGRES_PASSWORD"],
                database=os.environ["POSTGRES_DB"],
            )
            try:
                await conn.execute("SELECT home_ai.set_realm('work')")
                await conn.execute(
                    """INSERT INTO redaction_audit_log
                       (sha256_input, recognisers_hit, redacted_token_count,
                        input_length, status, workflow_id, capability_tag,
                        error_message, realm)
                       VALUES ($1, '{}'::jsonb, 0, $2,
                               'hard_fail', $3, $4, $5, 'work')""",
                    sha, len(prompt),
                    f"llm-router:{task_type}", task_type, str(e)[:500],
                )
            finally:
                await conn.close()
        except Exception as audit_err:
            # never block the 503 on audit-log write failure
            print(f"[u141] hard_fail audit-log write failed: {audit_err}")
        # No soft pass-through. Cloud-bound call is killed; caller sees 503.
        raise HTTPException(503, f"presidio redaction hard-fail: {e}")


async def _call_claude(http: httpx.AsyncClient, model: str, prompt: str,
                       task_type: str = "unknown") -> tuple[str, int, int, int]:
    # U141: redact BEFORE the API call. HARD-FAIL on Presidio outage.
    redacted_prompt = await _redact_via_presidio(http, prompt, task_type)

    start_time = time.time()
    try:
        response = await http.post(
            "https://api.anthropic.com/v1/messages",
            headers={
                "x-api-key": ANTHROPIC_API_KEY,
                "anthropic-version": "2023-06-01",
            },
            json={
                "model": model,
                "max_tokens": 1024,
                "messages": [{"role": "user", "content": redacted_prompt}],
            },
            timeout=30.0,
        )
        response.raise_for_status()
        data = response.json()
        text = data["content"][0]["text"]
        prompt_tokens = data["usage"]["input_tokens"]
        completion_tokens = data["usage"]["output_tokens"]
        latency_ms = int((time.time() - start_time) * 1000)
        return text, prompt_tokens, completion_tokens, latency_ms
    except HTTPException:
        # Re-raise our own (e.g. 503 from redactor) untouched
        raise
    except Exception as e:
        raise HTTPException(502, f"claude error: {e}")


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.pool = await asyncpg.create_pool(
        host=os.environ["POSTGRES_HOST"],
        port=int(os.environ["POSTGRES_PORT"]),
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
        database=os.environ["POSTGRES_DB"],
        min_size=1,
        max_size=4,
    )
    app.state.http = httpx.AsyncClient(timeout=10.0)
    app.state.redis = await redis.Redis(
        host=REDIS_HOST,
        port=6379,
        password=REDIS_PASSWORD,
        decode_responses=True,
    )
    try:
        yield
    finally:
        await app.state.http.aclose()
        await app.state.redis.close()
        await app.state.pool.close()


app = FastAPI(lifespan=lifespan)


@app.get("/healthcheck")
async def healthcheck():
    return {"status": "ok"}


@app.post("/route")
async def route(req: RouteRequest) -> RouteResponse:
    trace_id = req.trace_id or str(uuid.uuid4())
    start_time = time.time()

    cache_key = _cache_key(req.task_type, req.prompt)
    cached_value = await app.state.redis.get(cache_key)
    if cached_value:
        cached_response = json.loads(cached_value)
        cached_response["cached"] = True
        cached_response["trace_id"] = trace_id
        asyncio.create_task(
            _log_usage(
                app.state.pool, trace_id, req.entity_id, req.task_type,
                cached_response.get("model_used", "(cached)"),
                cached_response.get("tier", "hot"),
                False, None,
                cached_response.get("prompt_tokens", 0),
                cached_response.get("completion_tokens", 0),
                cached_response.get("latency_ms", 0),
                True,
            )
        )
        return RouteResponse(**cached_response)

    if req.task_type in CLAUDE_DIRECT:
        if await _over_hard_budget(app.state.pool):
            raise HTTPException(
                429,
                f"daily AI hard cap £{HARD_DAILY_CAP_GBP:.2f} exceeded — cloud paused "
                f"(runaway guard); retry tomorrow or raise HARD_DAILY_CAP_GBP")
        model_to_use = CLAUDE_DIRECT[req.task_type]
        text, prompt_tokens, completion_tokens, latency_ms = await _call_claude(
            app.state.http, model_to_use, req.prompt, task_type=req.task_type
        )
        response = RouteResponse(
            text=text,
            model_used=model_to_use,
            tier="claude",
            escalated=False,
            escalation_reason=None,
            latency_ms=latency_ms,
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            cached=False,
            trace_id=trace_id,
        )
        asyncio.create_task(
            _log_usage(
                app.state.pool,
                trace_id,
                req.entity_id,
                req.task_type,
                model_to_use,
                "claude",
                False,
                None,
                prompt_tokens,
                completion_tokens,
                latency_ms,
                False,
            )
        )
        return response

    tier = TASK_TIER_DEFAULT.get(req.task_type, "hot")
    model_tiers = await _get_model_tiers(app.state.pool)
    model_name = model_tiers.get(tier)

    if not model_name:
        asyncio.create_task(
            _log_usage(
                app.state.pool, trace_id, req.entity_id, req.task_type,
                "(none)", tier, False, f"no model deployed for tier '{tier}'",
                0, 0, 0, False,
            )
        )
        raise HTTPException(
            503, f"no model deployed for tier '{tier}' (task_type: {req.task_type})"
        )

    escalated = False
    escalation_reason = None
    text = ""
    prompt_tokens = 0
    completion_tokens = 0
    latency_ms = 0

    try:
        text, prompt_tokens, completion_tokens, latency_ms = await _call_ollama(
            app.state.http, model_name, req.prompt
        )

        try:
            parsed = json.loads(text)
            confidence = parsed.get("confidence_score", 0.0)
            thresholds = await _get_thresholds(app.state.pool)
            threshold = thresholds.get(tier, DEFAULT_THRESHOLDS[tier])

            if confidence < threshold:
                escalated = True
                escalation_reason = f"confidence {confidence:.3f} below threshold {threshold}"
        except (json.JSONDecodeError, ValueError):
            if req.task_type in ("email.classify", "invoice.extract", "child.classify"):
                escalated = True
                escalation_reason = "invalid json response"

    except HTTPException:
        escalated = True
        escalation_reason = "ollama unavailable or timed out"

    over_budget = escalated and req.allow_escalation and await _over_hard_budget(app.state.pool)
    if escalated and req.allow_escalation and not over_budget:
        model_to_use = "claude-haiku-4-5-20251001"
        try:
            text, prompt_tokens, completion_tokens, latency_ms = await _call_claude(
                app.state.http, model_to_use, req.prompt, task_type=req.task_type
            )
        except HTTPException as e:
            asyncio.create_task(
                _log_usage(
                    app.state.pool, trace_id, req.entity_id, req.task_type,
                    model_to_use, "claude", True,
                    f"{escalation_reason}; claude escalation failed: {e.detail}",
                    prompt_tokens, completion_tokens, latency_ms, False,
                )
            )
            raise
        tier = "claude"
    elif over_budget:
        # Hard budget cap hit — keep the free local result instead of escalating.
        # This is the designed degradation: the caller (e.g. invoice ladder) still
        # gets an answer, just the lower-confidence local one.
        escalation_reason = (
            f"{escalation_reason}; cloud escalation skipped (hard budget cap "
            f"£{HARD_DAILY_CAP_GBP:.2f})")
        escalated = False
        model_to_use = model_name
    elif escalated:
        asyncio.create_task(
            _log_usage(
                app.state.pool, trace_id, req.entity_id, req.task_type,
                model_name, tier, True, escalation_reason,
                prompt_tokens, completion_tokens, latency_ms, False,
            )
        )
        raise HTTPException(503, f"escalation needed but not allowed: {escalation_reason}")
    else:
        model_to_use = model_name
        if tier == "hot":
            await app.state.redis.setex(
                cache_key,
                3600,
                json.dumps(
                    {
                        "text": text,
                        "model_used": model_to_use,
                        "tier": tier,
                        "escalated": False,
                        "escalation_reason": None,
                        "latency_ms": latency_ms,
                        "prompt_tokens": prompt_tokens,
                        "completion_tokens": completion_tokens,
                    }
                ),
            )

    response = RouteResponse(
        text=text,
        model_used=model_to_use,
        tier=tier,
        escalated=escalated,
        escalation_reason=escalation_reason,
        latency_ms=latency_ms,
        prompt_tokens=prompt_tokens,
        completion_tokens=completion_tokens,
        cached=False,
        trace_id=trace_id,
    )

    asyncio.create_task(
        _log_usage(
            app.state.pool,
            trace_id,
            req.entity_id,
            req.task_type,
            model_to_use,
            tier,
            escalated,
            escalation_reason,
            prompt_tokens,
            completion_tokens,
            latency_ms,
            False,
        )
    )

    return response


@app.get("/stats")
async def stats():
    try:
        async with app.state.pool.acquire() as conn:
            cutoff = datetime.now(timezone.utc) - timedelta(hours=24)
            local_count = await conn.fetchval(
                "SELECT COUNT(*) FROM ai_usage WHERE escalated = FALSE AND timestamp > $1",
                cutoff,
            )
            escalated_count = await conn.fetchval(
                "SELECT COUNT(*) FROM ai_usage WHERE escalated = TRUE AND timestamp > $1",
                cutoff,
            )
            total_tokens = await conn.fetchval(
                "SELECT COALESCE(SUM(completion_tokens), 0) FROM ai_usage "
                "WHERE escalated = TRUE AND timestamp > $1",
                cutoff,
            )
        return {
            "period": "last 24h",
            "local_calls": local_count or 0,
            "escalated_calls": escalated_count or 0,
            "escalated_tokens_spent": total_tokens or 0,
            "estimated_cost_usd": (total_tokens or 0) * 0.00006,
        }
    except Exception as e:
        raise HTTPException(500, f"stats error: {e}")
