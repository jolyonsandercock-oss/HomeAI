# U231 — Postgres role migration path decision: A first, B later

**Decided:** 2026-05-29 by autonomous batch (per sprint plan recommendation; Jo approved blanket "run the batch").

**Chosen for first wave:** Path A — per-service DSN swap with Vault-Agent templated password files.

**Deferred to second wave (likely U231b):** Path B — per-request `SET ROLE` for services with realm multiplexing (bot-responder, frontend).

**Rationale:**
- Path A migrations are independent — one service at a time, low blast radius if any one swap goes wrong.
- Paperless already proved the pattern in 2026-05-28 recovery (U70 — fetch from vault, env_file substitution, recreate).
- Path B needs application-level wiring (transaction-scoped SET ROLE on every request) — heavier touch, better justified once Path A reveals which services actually multiplex.

**Migration order (least-disruptive first):**
1. `paperless` — already isolated, lowest blast radius
2. `metabase` — read-mostly
3. `homeai_readonly` for `build-dashboard`, `mcp-server`
4. `alert_sink` (n8n credential)
5. `bot-responder` — Path B target, leave on superuser until U231b
6. `n8n` engine — stays on superuser (owns its own schema)

**Verification per step:** `selftest.sh` clean + 24h soak with no service-down alerts.
