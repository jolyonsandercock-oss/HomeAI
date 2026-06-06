# lib/claude_call.py — API retry/cooldown protocol

Shared helper so background jobs don't stall on transient Anthropic API errors
(esp. `529 overloaded_error`). Added after a 2026-06 audit found 529s scattered
across many jobs (u46 logged 674) because most call sites had no retry.

## The protocol

Retryable: HTTP `408/409/429/500/502/503/529`, `overloaded_error`, and
connection/timeout errors. Two layers of patience:

1. **Inner (SDK):** the Anthropic SDK's own `max_retries` — fast exponential
   backoff + jitter, honors `Retry-After`. Rides out brief blips (seconds).
2. **Outer (this helper):** a cooldown loop for *sustained* outages — when the
   SDK gives up, wait a longer growing cooldown (20s → minutes, full jitter) and
   retry the whole call. Background batches wait instead of dropping work.

Every retry logs: `[claude_call] 529 — cooldown 47s (outer 2/4)`. After all
attempts it raises, so the caller can record the item for a later sweep.

## Adoption

**SDK callers** (`anthropic.Anthropic(...)`): just pass `max_retries` — the
default of 2 is too low for a sustained overload. Use 8:
```python
client = anthropic.Anthropic(api_key=key, max_retries=8, timeout=120)
```
(Done for all SDK call sites in `scripts/` + `services/` as of 2026-06-06.)

**Raw-HTTP callers** (`urllib`/`httpx` to `api.anthropic.com`): use the helper.
Since most run inside `homeai-bot-responder` via `docker exec python3 -`, prepend
the helper at invocation (no container rebuild, no mount needed):
```bash
# wrapper .sh — instead of:  docker exec -i homeai-bot-responder python3 - < foo.py
cat /home_ai/lib/claude_call.py /home_ai/scripts/foo.py | docker exec -i homeai-bot-responder python3 -
```
For heredoc wrappers (`python -u <<'PYEOF' … PYEOF`), write the combined file to
a temp and run it, or convert the inline raw call to the SDK with `max_retries=8`.

Then in the script:
```python
resp = claude_messages({"model": "claude-haiku-4-5-20251001", "max_tokens": 1024,
                        "messages": [{"role": "user", "content": prompt}]})
text = resp["content"][0]["text"]          # returns a plain dict (model_dump)
```
Async: `resp = await claude_messages_async({...})`.

## Raw-HTTP call sites — retrofit status (U245, 2026-06-06)

All retrofitted (syntax-verified; behaviour verified on next cron run):
- `u61-line-items` (33×529, bot-responder) → `claude_call.claude_messages_async`.
- `u47e-uncertain-resolve` (22, playwright) → inline stdlib retry.
- `u120-extract-guest-contact` (host) → inline retry.
- `u113-kitchen-specials` (bot-responder) → inline retry.
- `u159-revenue-email` (playwright `-c`) → inline retry.
- `u163-reviews-from-email` (host) → inline retry (was catch-and-drop).
- `u216-mortgage-reocr-wrapper` (playwright `-c` probe) → probe retries before skip.
- `u151b-reocr-vision` — already hardened (U216 retry loop); no change.
- `u161-vision-ocr-worker` — delegates to u151b; no own Anthropic call.

`u66-telegram-bot` errors are transient long-poll network blips (ConnectError to
Telegram), not 529s — log-noise, not data loss; left as-is.

Pattern: bot-responder scripts → `import claude_call`; playwright/host scripts →
inline stdlib retry on 408/409/429/5xx/529 + transient network, exp backoff.
