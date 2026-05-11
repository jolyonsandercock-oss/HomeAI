# 2026-05-08 — `init_placeholder` HMAC trigger fix — already resolved

## Status: Done in V4 (applied)

When this issue was first flagged in AGENTS.md gotchas (2026-05-02), the
plan was to fix the trigger so that it computes a real HMAC-SHA256 signature
using the key from Vault. That plan was superseded by V4.

## What V4 did

`postgres/migrations/V4__drop_static_context_trigger.sql` (applied):

```sql
DROP TRIGGER IF EXISTS static_context_change ON static_context;
DROP FUNCTION IF EXISTS notify_context_change();
```

Verified applied: `SELECT count(*) FROM pg_trigger WHERE tgname='static_context_change'` → 0.

## Why dropping was the right call (vs fixing)

Computing HMAC inside the trigger function was awkward:
- pgcrypto's `hmac()` works, but the signing key would have to live in a
  Postgres GUC or be set per-session via `SET LOCAL app.signing_key`
- Either approach moves the signing key out of Vault and into Postgres'
  process memory or session state — security regression
- Also: the trigger fired in the calling user's RLS context, which (before
  V3) blocked event INSERTs entirely

Architectural fix: emit `system.config_change` events from application code
that already has access to `PAYLOAD_HMAC_KEY` via Vault-derived env var
(per the `_set_system_entity` + sign-emit pattern in
`services/model-evaluator/main.py` deploy_model endpoint).

## Implications for future work

Anything that mutates `static_context` and wants to emit a corresponding
`system.config_change` event must:

1. Build the payload dict
2. Compute `HMAC-SHA256(canonical_json(payload), PAYLOAD_HMAC_KEY)` for
   `payload_signature`
3. INSERT into `events` directly (idempotency_key required per build rule)
4. Write a corresponding `audit_log` row

This is now the convention. There is no trigger to lean on.

Reference implementation: `services/model-evaluator/main.py` deploy_model
(lines ~189-223). Same pattern goes into the email_pipeline workflow
(see `n8n-exports/email-pipeline.json` — `Sign + Emit email.classified`
node).

## AGENTS.md gotcha — needs cleanup

The skill gotcha entry in `AGENTS.md` at lines 119-125 describes the
trigger as still-present and "needs a dedicated step to fix." That's now
inaccurate. The entry should be replaced (not just deleted) with a
forward-looking note: "Anything that needs to emit a `system.config_change`
event must build it in application code with proper HMAC signing — there
is no trigger to lean on."

Action item: refresh that gotcha block in next AGENTS.md edit pass.
