# lib/claude_call.py — shared Anthropic call helper with a retry/cooldown protocol
# so background jobs don't stall on transient API-side errors (esp. 529 overloaded).
#
# THE PROTOCOL
#   Retryable: HTTP 408/409/429/500/502/503/529, overloaded_error, and
#   connection/timeout errors. Two layers of patience:
#     1. Inner: the Anthropic SDK's own retries (max_retries) — fast exponential
#        backoff + jitter, honors Retry-After. Rides out brief blips (seconds).
#     2. Outer: a cooldown loop here for SUSTAINED outages — when the SDK gives
#        up, wait a longer, growing cooldown (tens of seconds to minutes) and try
#        the whole call again. Background work waits instead of dropping items.
#   Every retry is logged: "[claude_call] 529 overloaded — cooldown 47s (2/4)".
#   After all attempts it raises, so the caller can record the item for a sweep.
#
# USAGE (sync)   from a stdin-piped script, prepend this file:
#     cat /home_ai/lib/claude_call.py /home_ai/scripts/foo.py | docker exec -i homeai-bot-responder python3 -
#   then in foo.py just call:
#     resp = claude_messages({"model": "claude-haiku-4-5-20251001",
#                             "max_tokens": 1024,
#                             "messages": [{"role": "user", "content": prompt}]})
#     text = resp["content"][0]["text"]
#
# USAGE (async)  resp = await claude_messages_async({...})
#
# SDK callers that already build their own client should instead just pass
# max_retries (and a timeout) — that turns on layer 1. The default of 2 is too
# low for a sustained overload; use 8.
import os, time, random, json, urllib.request

_RETRYABLE_STATUS = {408, 409, 429, 500, 502, 503, 529}
_DEFAULT_MODEL = "claude-haiku-4-5-20251001"


def _resolve_api_key(explicit=None):
    if explicit:
        return explicit
    for var in ("ANTHROPIC_API_KEY", "ANTHROPIC_KEY"):
        if os.environ.get(var):
            return os.environ[var]
    # last resort: Vault (same path llm-router uses), needs VAULT_TOKEN in env
    tok = os.environ.get("VAULT_TOKEN")
    if tok:
        try:
            r = urllib.request.Request("http://vault:8200/v1/secret/data/anthropic",
                                       headers={"X-Vault-Token": tok})
            data = json.loads(urllib.request.urlopen(r, timeout=5).read())["data"]["data"]
            return data.get("api_key") or data.get("ANTHROPIC_API_KEY")
        except Exception as e:
            raise RuntimeError(f"claude_call: could not resolve Anthropic key from Vault: {e}")
    raise RuntimeError("claude_call: no Anthropic API key (set ANTHROPIC_API_KEY or VAULT_TOKEN)")


def _is_retryable(exc):
    status = getattr(exc, "status_code", None)
    if status in _RETRYABLE_STATUS:
        return True
    name = type(exc).__name__
    if name in ("APIConnectionError", "APITimeoutError", "InternalServerError",
                "RateLimitError", "OverloadedError"):
        return True
    return "overloaded" in str(exc).lower()


def _cooldown(attempt, base, cap):
    # exponential growth with full jitter
    return min(cap, base * (2 ** attempt)) + random.uniform(0, base)


def claude_messages(body, *, api_key=None, max_retries=8, outer_retries=4,
                    outer_base=20.0, outer_cap=300.0, timeout=120.0, log=print):
    """Synchronous messages.create with the retry/cooldown protocol. Returns a
    plain dict (resp.model_dump()) so it is a drop-in for raw-urllib callers."""
    import anthropic
    body = dict(body)
    body.setdefault("model", _DEFAULT_MODEL)
    client = anthropic.Anthropic(api_key=_resolve_api_key(api_key),
                                 max_retries=max_retries, timeout=timeout)
    for attempt in range(outer_retries + 1):
        try:
            return client.messages.create(**body).model_dump()
        except Exception as exc:
            if not _is_retryable(exc) or attempt == outer_retries:
                raise
            wait = _cooldown(attempt, outer_base, outer_cap)
            status = getattr(exc, "status_code", type(exc).__name__)
            log(f"[claude_call] {status} — cooldown {wait:.0f}s "
                f"(outer {attempt + 1}/{outer_retries})")
            time.sleep(wait)


async def claude_messages_async(body, *, api_key=None, max_retries=8, outer_retries=4,
                                outer_base=20.0, outer_cap=300.0, timeout=120.0, log=print):
    """Async variant for httpx/asyncio call sites. Same protocol."""
    import anthropic, asyncio
    body = dict(body)
    body.setdefault("model", _DEFAULT_MODEL)
    client = anthropic.AsyncAnthropic(api_key=_resolve_api_key(api_key),
                                      max_retries=max_retries, timeout=timeout)
    for attempt in range(outer_retries + 1):
        try:
            resp = await client.messages.create(**body)
            return resp.model_dump()
        except Exception as exc:
            if not _is_retryable(exc) or attempt == outer_retries:
                raise
            wait = _cooldown(attempt, outer_base, outer_cap)
            status = getattr(exc, "status_code", type(exc).__name__)
            log(f"[claude_call] {status} — cooldown {wait:.0f}s "
                f"(outer {attempt + 1}/{outer_retries})")
            await asyncio.sleep(wait)
