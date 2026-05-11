import hashlib
import hmac
import json
import os
import re
import uuid
from contextlib import asynccontextmanager
from typing import Literal

import asyncpg
import httpx
from fastapi import FastAPI, HTTPException

from benchmark_tasks import (
    EMAIL_CLASSIFICATION_SAMPLES,
    JSON_FORMAT_PROMPTS,
    INVOICE_EXTRACTION_SAMPLES,
    REPORT_PARSING_SAMPLES,
)
from qwen_prompts import EMAIL_TASK, INVOICE_TASK, REPORT_TASK, build_request

OLLAMA_HOST = os.environ["OLLAMA_HOST"]
PAYLOAD_HMAC_KEY = os.environ["PAYLOAD_HMAC_KEY"]


def _parse_json_loose(text: str) -> dict | None:
    """Greedy match the outermost {...} in a model response."""
    if not text:
        return None
    text = text.strip()
    text = re.sub(r"^```[a-z]*\n?", "", text).rstrip("`").rstrip()
    s, e = text.find("{"), text.rfind("}")
    if s < 0 or e < 0 or e <= s:
        return None
    try:
        return json.loads(text[s:e + 1])
    except Exception:
        return None


def _score_email(text: str, expected: dict) -> float:
    p = _parse_json_loose(text)
    if not p:
        return 0.0
    cat_ok = p.get("category") == expected["category"]
    raw_eid = p.get("entity_id")
    try:
        eid = int(raw_eid) if raw_eid is not None else None
    except (TypeError, ValueError):
        eid = None
    if cat_ok and eid == expected["entity_id"]:
        return 1.0
    return 0.5 if cat_ok else 0.0


def _score_fields(text: str, expected: dict) -> float:
    p = _parse_json_loose(text)
    if not p:
        return 0.0
    matches = 0
    for k, v in expected.items():
        got = p.get(k)
        if isinstance(v, (int, float)) and isinstance(got, (int, float)):
            if abs(float(got) - float(v)) <= 0.05:
                matches += 1
        elif str(got or "").strip().lower() == str(v).strip().lower():
            matches += 1
    return matches / len(expected) if expected else 0.0


def sign_payload(payload: dict) -> str:
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hmac.new(
        PAYLOAD_HMAC_KEY.encode(), canonical.encode(), hashlib.sha256
    ).hexdigest()

async def _set_system_entity(conn) -> None:
    await conn.execute("SET LOCAL app.current_entity = 'all'")


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
    try:
        yield
    finally:
        await app.state.http.aclose()
        await app.state.pool.close()


app = FastAPI(lifespan=lifespan)


@app.get("/healthcheck")
async def healthcheck():
    return {"status": "ok"}


async def _scan() -> dict:
    try:
        r = await app.state.http.get(f"{OLLAMA_HOST}/api/tags")
        r.raise_for_status()
    except httpx.HTTPError as e:
        raise HTTPException(502, f"ollama unreachable: {e}")

    models = r.json().get("models", [])
    new_models: list[str] = []
    updated_models: list[str] = []

    async with app.state.pool.acquire() as conn:
        async with conn.transaction():
            await _set_system_entity(conn)
            for m in models:
                name = m["name"]
                digest = m.get("digest")
                inserted = await conn.fetchval(
                    """INSERT INTO model_registry
                         (model_name, installed, ollama_digest, last_seen_in_registry)
                       VALUES ($1, TRUE, $2, NOW())
                       ON CONFLICT (model_name) DO UPDATE
                         SET installed = TRUE,
                             ollama_digest = EXCLUDED.ollama_digest,
                             last_seen_in_registry = NOW()
                       RETURNING (xmax = 0) AS inserted""",
                    name, digest,
                )
                (new_models if inserted else updated_models).append(name)

            await conn.execute(
                """INSERT INTO model_scan_log
                     (models_found, new_models, updated_models, scan_source)
                   VALUES ($1, $2, $3, 'ollama_local')""",
                len(models), new_models, updated_models,
            )

    return {
        "models_found": len(models),
        "new_models": new_models,
        "updated_models": updated_models,
    }


@app.post("/api/scan")
async def scan_installed_models():
    return await _scan()


@app.get("/api/models")
async def list_models():
    async with app.state.pool.acquire() as conn:
        rows = await conn.fetch(
            """SELECT model_name, family, params_b, vram_gb, installed,
                      deployed_tier, ollama_digest, last_seen_in_registry
                 FROM model_registry
             ORDER BY model_name"""
        )
        tiers_raw = await conn.fetchval(
            "SELECT value FROM static_context WHERE key = 'model.tiers'"
        )

    tiers = json.loads(tiers_raw) if tiers_raw else {}
    return {"models": [dict(r) for r in rows], "tiers": tiers}


@app.post("/api/models/{model_name}/deploy/{tier}")
async def deploy_model(
    model_name: str,
    tier: Literal["hot", "medium", "heavy"],
):
    async with app.state.pool.acquire() as conn:
        async with conn.transaction():
            await _set_system_entity(conn)
            installed = await conn.fetchval(
                "SELECT installed FROM model_registry WHERE model_name = $1",
                model_name,
            )
            if installed is None:
                raise HTTPException(404, f"model not in registry: {model_name}")
            if not installed:
                raise HTTPException(409, f"model not installed: {model_name}")

            previous = await conn.fetchval(
                "SELECT value FROM static_context WHERE key = 'model.tiers'"
            )
            await conn.execute(
                """UPDATE model_registry
                      SET deployed_tier = CASE
                          WHEN model_name = $1 THEN $2
                          WHEN deployed_tier = $2 THEN NULL
                          ELSE deployed_tier
                      END
                    WHERE model_name = $1 OR deployed_tier = $2""",
                model_name, tier,
            )
            await conn.execute(
                """INSERT INTO static_context (key, value)
                   VALUES ('model.tiers', $1::jsonb)
                   ON CONFLICT (key) DO UPDATE
                     SET value = static_context.value || EXCLUDED.value,
                         updated_at = NOW()""",
                json.dumps({tier: model_name}),
            )

            payload = {
                "key": "model.tiers",
                "model": model_name,
                "tier": tier,
                "previous": json.loads(previous) if previous else {},
                "current": {**(json.loads(previous) if previous else {}), tier: model_name},
            }
            await conn.execute(
                """INSERT INTO events
                     (event_type, source, payload, payload_signature,
                      idempotency_key, status)
                   VALUES ($1, $2, $3::jsonb, $4, $5, 'pending')""",
                "system.config_change",
                "model-evaluator",
                json.dumps(payload),
                sign_payload(payload),
                f"deploy_{tier}_{model_name}_{uuid.uuid4()}",
            )

    return {"status": "deployed", "model": model_name, "tier": tier}


async def _run_one(model_name: str, body_extras: dict, prompt: str) -> dict:
    """Single Ollama call with the U7 sampling defaults baked in. body_extras
    overrides options/system/format from qwen_prompts.build_request."""
    body = {**body_extras, "model": model_name, "prompt": prompt, "stream": False}
    try:
        r = await app.state.http.post(f"{OLLAMA_HOST}/api/generate", json=body, timeout=180.0)
        r.raise_for_status()
        d = r.json()
        eval_count = d.get("eval_count", 0) or 0
        eval_dur = d.get("eval_duration", 0) or 0
        total_dur = d.get("total_duration", 0) or 0
        return {
            "text": d.get("response", ""),
            "speed_tps": (eval_count / (eval_dur / 1e9)) if eval_dur > 0 else 0.0,
            "latency_ms": total_dur // 1_000_000,
            "input_tokens": d.get("prompt_eval_count", 0) or 0,
            "output_tokens": eval_count,
            "error": None,
        }
    except httpx.HTTPError as e:
        return {"text": "", "speed_tps": 0.0, "latency_ms": 0,
                "input_tokens": 0, "output_tokens": 0, "error": str(e)}


async def _benchmark(model_name: str, tier: str) -> dict:
    """Comprehensive benchmark — emails, JSON validity, invoice extraction,
    report parsing — using the U7-optimised prompts. Results land in
    benchmark_results (per-task) and model_scores (aggregate)."""
    run_id = uuid.uuid4()
    results: list[dict] = []
    speeds: list[float] = []
    latencies: list[int] = []
    cat_scores: dict[str, list[float]] = {"email": [], "json": [], "invoice": [], "report": []}

    # Email classification
    for s in EMAIL_CLASSIFICATION_SAMPLES:
        body = build_request(EMAIL_TASK, model=model_name,
                             f=s["from"], s=s["subject"], b=s["body"])
        body_extras = {k: body[k] for k in ("format", "system", "options")}
        out = await _run_one(model_name, body_extras, body["prompt"])
        sc = _score_email(out["text"], s["expected"])
        cat_scores["email"].append(sc)
        if out["error"] is None:
            speeds.append(out["speed_tps"]); latencies.append(out["latency_ms"])
        results.append({"task_id": s["id"], "category": "email", "score": int(sc * 100),
                        "passed": sc >= 1.0, "speed_tps": out["speed_tps"],
                        "latency_ms": out["latency_ms"], "input_tokens": out["input_tokens"],
                        "output_tokens": out["output_tokens"], "raw_output": out["text"][:1000],
                        "error_message": out["error"]})

    # JSON validity (no template — raw prompts)
    json_body = {"format": "json", "system": EMAIL_TASK["system"],
                 "options": {"temperature": 0.0, "top_p": 0.7, "top_k": 40}}
    for i, prompt in enumerate(JSON_FORMAT_PROMPTS):
        out = await _run_one(model_name, json_body, prompt)
        sc = 1.0 if _parse_json_loose(out["text"]) is not None else 0.0
        cat_scores["json"].append(sc)
        if out["error"] is None:
            speeds.append(out["speed_tps"]); latencies.append(out["latency_ms"])
        results.append({"task_id": f"json_{i:02d}", "category": "json", "score": int(sc * 100),
                        "passed": sc >= 1.0, "speed_tps": out["speed_tps"],
                        "latency_ms": out["latency_ms"], "input_tokens": out["input_tokens"],
                        "output_tokens": out["output_tokens"], "raw_output": out["text"][:1000],
                        "error_message": out["error"]})

    # Invoice extraction
    for s in INVOICE_EXTRACTION_SAMPLES:
        body = build_request(INVOICE_TASK, model=model_name, t=s["text"])
        body_extras = {k: body[k] for k in ("format", "system", "options")}
        out = await _run_one(model_name, body_extras, body["prompt"])
        sc = _score_fields(out["text"], s["expected"])
        cat_scores["invoice"].append(sc)
        if out["error"] is None:
            speeds.append(out["speed_tps"]); latencies.append(out["latency_ms"])
        results.append({"task_id": s["id"], "category": "invoice", "score": int(sc * 100),
                        "passed": sc >= 0.8, "speed_tps": out["speed_tps"],
                        "latency_ms": out["latency_ms"], "input_tokens": out["input_tokens"],
                        "output_tokens": out["output_tokens"], "raw_output": out["text"][:1000],
                        "error_message": out["error"]})

    # Report parsing
    for s in REPORT_PARSING_SAMPLES:
        body = build_request(REPORT_TASK, model=model_name, t=s["text"])
        body_extras = {k: body[k] for k in ("format", "system", "options")}
        out = await _run_one(model_name, body_extras, body["prompt"])
        sc = _score_fields(out["text"], s["expected"])
        cat_scores["report"].append(sc)
        if out["error"] is None:
            speeds.append(out["speed_tps"]); latencies.append(out["latency_ms"])
        results.append({"task_id": s["id"], "category": "report", "score": int(sc * 100),
                        "passed": sc >= 0.8, "speed_tps": out["speed_tps"],
                        "latency_ms": out["latency_ms"], "input_tokens": out["input_tokens"],
                        "output_tokens": out["output_tokens"], "raw_output": out["text"][:1000],
                        "error_message": out["error"]})

    n = len(results)
    cat_means = {k: (sum(v) / len(v) * 100 if v else 0) for k, v in cat_scores.items()}
    accuracy = sum(cat_means.values()) / 4               # equal-weight 4 categories
    avg_speed = sum(speeds) / len(speeds) if speeds else 0.0
    avg_latency = (sum(latencies) // len(latencies)) if latencies else 0
    speed_score = min(100.0, avg_speed / 60.0 * 100.0)   # hot-tier target 60 t/s
    format_score = cat_means["json"]                     # JSON-validity is the format proxy
    composite = 0.7 * accuracy + 0.3 * speed_score

    async with app.state.pool.acquire() as conn:
        async with conn.transaction():
            await _set_system_entity(conn)
            for r in results:
                await conn.execute(
                    """INSERT INTO benchmark_results
                         (model_name, run_id, tier, task_id, score, speed_tps,
                          latency_ms, input_tokens, output_tokens, passed,
                          raw_output, error_message)
                       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)""",
                    model_name, run_id, tier, r["task_id"], r["score"],
                    r["speed_tps"], r["latency_ms"], r["input_tokens"],
                    r["output_tokens"], r["passed"], r["raw_output"],
                    r["error_message"],
                )
            await conn.execute(
                """INSERT INTO model_scores
                     (model_name, tier, composite_score, accuracy_score,
                      speed_score, format_score, avg_speed_tps,
                      avg_latency_ms, task_count)
                   VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
                   ON CONFLICT (model_name, tier, score_date) DO UPDATE SET
                     composite_score = EXCLUDED.composite_score,
                     accuracy_score  = EXCLUDED.accuracy_score,
                     speed_score     = EXCLUDED.speed_score,
                     format_score    = EXCLUDED.format_score,
                     avg_speed_tps   = EXCLUDED.avg_speed_tps,
                     avg_latency_ms  = EXCLUDED.avg_latency_ms,
                     task_count      = EXCLUDED.task_count,
                     scored_at       = NOW()""",
                model_name, tier, composite, accuracy, speed_score,
                format_score, avg_speed, avg_latency, n,
            )

    return {
        "model": model_name,
        "tier": tier,
        "run_id": str(run_id),
        "task_count": n,
        "passed": sum(1 for r in results if r["passed"]),
        "composite_score": round(composite, 2),
        "accuracy_score": round(accuracy, 2),
        "speed_score": round(speed_score, 2),
        "format_score": round(format_score, 2),
        "avg_speed_tps": round(avg_speed, 2),
        "avg_latency_ms": avg_latency,
        "category_breakdown": {k: round(v, 1) for k, v in cat_means.items()},
    }


@app.post("/webhook/model-evaluator-manual")
async def manual_trigger(
    model: str | None = None,
    tier: str | None = None,
):
    """If `model` is provided: benchmark just that model at the given tier
    (default 'hot'). Otherwise scan + sweep ALL installed models so the
    leaderboard reflects every locally-resident option."""
    scan_result = await _scan()

    if model:
        benchmark_result = await _benchmark(model, tier or "hot")
        return {"scan": scan_result, "benchmark": benchmark_result}

    # Sweep mode: every installed model at its deployed_tier (or 'hot' if unset)
    async with app.state.pool.acquire() as conn:
        rows = await conn.fetch(
            """SELECT model_name, deployed_tier
                 FROM model_registry
                WHERE installed = TRUE
             ORDER BY model_name"""
        )

    sweep_results = []
    for r in rows:
        try:
            res = await _benchmark(r["model_name"], r["deployed_tier"] or "hot")
            sweep_results.append(res)
        except Exception as e:  # one model failure shouldn't kill the sweep
            sweep_results.append({
                "model": r["model_name"],
                "tier": r["deployed_tier"] or "hot",
                "error": str(e),
            })

    return {"scan": scan_result, "sweep": sweep_results}
