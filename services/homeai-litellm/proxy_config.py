"""
LiteLLM custom callbacks — Presidio gate + ai_usage logger.

Loaded via `callbacks:` in config.yaml. Each callback is a LiteLLM
CustomLogger subclass; LiteLLM calls async_pre_call_hook for redaction
and async_post_call_success_hook for telemetry.
"""

import hashlib
import json
import os
import time
import urllib.request

import asyncpg

from litellm.integrations.custom_logger import CustomLogger
from litellm.proxy.proxy_server import UserAPIKeyAuth

PRESIDIO_URL = os.environ.get("PRESIDIO_URL", "http://homeai-presidio:8765")
PRESIDIO_REQUIRED = os.environ.get("PRESIDIO_REQUIRED", "1") == "1"

PG_HOST = os.environ.get("POSTGRES_HOST", "homeai-postgres")
PG_PORT = int(os.environ.get("POSTGRES_PORT", "5432"))
PG_USER = os.environ.get("POSTGRES_USER", "homeai_pipeline")
PG_PW   = os.environ.get("POSTGRES_PASSWORD", "")
PG_DB   = os.environ.get("POSTGRES_DB",   "homeai")


def _dsn() -> str:
    return f"postgresql://{PG_USER}:{PG_PW}@{PG_HOST}:{PG_PORT}/{PG_DB}"


# ============================================================================
# 1. PresidioGate — HARD-FAIL redaction before the upstream call
# ============================================================================
class PresidioGate(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        if not PRESIDIO_REQUIRED:
            return data
        msgs = data.get("messages") or []
        model = data.get("model", "unknown")
        for m in msgs:
            content = m.get("content")
            if isinstance(content, str) and content:
                redacted = await self._redact(content, model)
                m["content"] = redacted
            elif isinstance(content, list):
                for blk in content:
                    if isinstance(blk, dict) and blk.get("type") == "text":
                        blk["text"] = await self._redact(blk["text"], model)
        # Also redact system prompt if string
        if isinstance(data.get("system"), str):
            data["system"] = await self._redact(data["system"], model)
        return data

    async def _redact(self, text: str, model: str) -> str:
        if not text or not text.strip():
            return text
        try:
            body = json.dumps({
                "text": text,
                "workflow_id": f"litellm:{model}",
                "capability_tag": model,
                "realm": "work",
            }).encode()
            req = urllib.request.Request(
                f"{PRESIDIO_URL}/redact",
                data=body,
                headers={"Content-Type": "application/json"},
            )
            resp = urllib.request.urlopen(req, timeout=10)
            return json.loads(resp.read())["redacted_text"]
        except Exception as e:
            await self._log_hard_fail(text, model, str(e))
            # HARD-FAIL: raise so LiteLLM aborts the call. The caller
            # receives a 503-equivalent from the proxy.
            raise RuntimeError(f"presidio redaction hard-fail: {e}")

    async def _log_hard_fail(self, text: str, model: str, err: str):
        try:
            conn = await asyncpg.connect(_dsn())
            try:
                await conn.execute("SELECT home_ai.set_realm('work')")
                await conn.execute(
                    """INSERT INTO redaction_audit_log
                       (sha256_input, recognisers_hit, redacted_token_count,
                        input_length, status, workflow_id, capability_tag,
                        error_message, realm)
                       VALUES ($1, '{}'::jsonb, 0, $2,
                               'hard_fail', $3, $4, $5, 'work')""",
                    hashlib.sha256(text.encode("utf-8")).hexdigest(),
                    len(text), f"litellm:{model}", model, err[:500],
                )
            finally:
                await conn.close()
        except Exception:
            pass  # never block raise on audit-log failure


# ============================================================================
# 2. AiUsageLogger — write a row to ai_usage on every successful call
# ============================================================================
class AiUsageLogger(CustomLogger):
    async def async_post_call_success_hook(
        self, data, user_api_key_dict, response,
    ):
        try:
            usage = response.get("usage", {}) or {}
            model = response.get("model") or data.get("model") or "unknown"
            workflow_id = data.get("metadata", {}).get("workflow_id")
            conn = await asyncpg.connect(_dsn())
            try:
                await conn.execute("SELECT home_ai.set_realm('work')")
                # business_priority + capability_tag + cost_gbp are auto-populated by V175 trigger
                await conn.execute(
                    """INSERT INTO ai_usage
                       (task_type, model_used, tier, escalated, prompt_tokens,
                        completion_tokens, cache_creation_tokens, cache_read_tokens,
                        latency_ms, cached, provider, realm, service,
                        workflow_id, capability_tag, system_fingerprint)
                       VALUES ($1, $2, 'heavy', false, $3, $4, $5, $6, $7,
                               false, 'anthropic', 'work', 'litellm',
                               $8, $9, $10)""",
                    str(data.get("model", "unknown")),  # task_type used as capability identity
                    model,
                    usage.get("prompt_tokens", 0),
                    usage.get("completion_tokens", 0),
                    usage.get("cache_creation_input_tokens", 0) or 0,
                    usage.get("cache_read_input_tokens", 0) or 0,
                    int(response.get("_response_ms", 0) or 0),
                    workflow_id,
                    data.get("model"),
                    response.get("system_fingerprint"),
                )
            finally:
                await conn.close()
        except Exception:
            pass  # never block response on telemetry failure


# Module-level instances. LiteLLM resolves "module.attr" callback paths
# to attributes, not class names, so we provide instances here.
presidio_gate_instance = PresidioGate()
ai_usage_logger_instance = AiUsageLogger()
