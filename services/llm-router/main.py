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

OLLAMA_HOST = os.environ["OLLAMA_HOST"]
ANTHROPIC_API_KEY = os.environ["ANTHROPIC_API_KEY"]
REDIS_HOST = os.environ["REDIS_HOST"]
REDIS_PASSWORD = os.environ["REDIS_PASSWORD"]

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


async def _call_claude(http: httpx.AsyncClient, model: str, prompt: str) -> tuple[str, int, int, int]:
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
                "messages": [{"role": "user", "content": prompt}],
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
        model_to_use = CLAUDE_DIRECT[req.task_type]
        text, prompt_tokens, completion_tokens, latency_ms = await _call_claude(
            app.state.http, model_to_use, req.prompt
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

    if escalated and req.allow_escalation:
        model_to_use = "claude-haiku-4-5-20251001"
        try:
            text, prompt_tokens, completion_tokens, latency_ms = await _call_claude(
                app.state.http, model_to_use, req.prompt
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
