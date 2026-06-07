# Invariant Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the AGENTS-invariant violations surfaced by the 2026-06-07 audit, and wire the new `scripts/audit-invariants.py` checker in as a regression gate so they cannot silently return.

**Architecture:** The checker (`scripts/audit-invariants.py`) is the verification harness for this plan — every fix is "done" only when its specific finding clears in the checker output. Fixes touch three layers: n8n workflow exports (pushed to the live runtime via the n8n REST API, **not** by editing the export file alone), `docker-compose.yml`, and the `build-dashboard` service.

**Tech Stack:** Python 3 (stdlib), PostgreSQL (partitioned `events` + RLS), n8n (workflow_history runtime), Docker Compose, HashiCorp Vault.

**Scope note:** Task 6 (superuser→scoped-role migration, the U151b item) is a large independent subsystem with a grant-gap-audit dependency. It is summarised here but should get its **own** plan before execution — do not attempt it inline with the surgical fixes.

---

## Critical mechanic: how to edit a live n8n workflow

Editing a file in `/home_ai/.claude/n8n-exports/*.json` changes **nothing** at runtime. n8n executes the version pointed to by `workflow_entity.activeVersionId` → `workflow_history`. The safe path:

1. Pull current state with the n8n REST API (token auto-renews via Vault):
   ```bash
   N8N=http://homeai-n8n:5678
   TOK=$(cat /tmp/n8n_token 2>/dev/null)   # or fetch from Vault: secret/n8n
   curl -s -H "X-N8N-API-KEY: $TOK" "$N8N/api/v1/workflows?limit=250" \
     | python3 -c "import sys,json;[print(w['id'],w['name']) for w in json.load(sys.stdin)['data']]"
   ```
2. Export → edit JSON → `PUT /api/v1/workflows/:id` (this creates a new `workflow_history` row and repoints `activeVersionId` correctly).
3. Re-activate if needed: `POST /api/v1/workflows/:id/activate`.
4. Update the matching file under `.claude/n8n-exports/` so the repo copy stays canonical.
5. **Always** check the kill switch first: `SELECT value FROM static_context WHERE key='system.state'` — if `paused`, stop.

If the API is unavailable, the DB-edit fallback **must** insert a new `workflow_history` row and repoint `activeVersionId` — editing `workflow_entity.nodes` in place is a no-op.

---

## Task 1: F9 — events INSERT must not use ON CONFLICT (email-pipeline)

**Why:** `events` has `PRIMARY KEY (id, created_at)` and only a *non-unique* partial index on `idempotency_key`. `ON CONFLICT (idempotency_key)` has no matching unique constraint → throws *"no unique or exclusion constraint matching the ON CONFLICT specification"* at runtime. Every sibling pipeline already uses `WHERE NOT EXISTS`; this one node diverged.

**Files:**
- Modify: live workflow "Email Pipeline", node `Write Events + Audit + Mark Done`
- Modify: `.claude/n8n-exports/email-pipeline.json` (repo copy)
- Test: `scripts/audit-invariants.py` (INV-IDEMPOTENCY)

- [ ] **Step 1: Confirm the checker flags it (red baseline)**

Run: `python3 scripts/audit-invariants.py | grep INV-IDEMPOTENCY`
Expected: one line referencing `email-pipeline.json » node 'Write Events + Audit + Mark Done'`.

- [ ] **Step 2: Replace the `VALUES … ON CONFLICT` block with `SELECT … WHERE NOT EXISTS`**

In the node's query, change the `new_event` CTE from:

```sql
  INSERT INTO events
    (event_type, source, entity_id, payload, payload_signature,
     status, trace_id, parent_event_id, idempotency_key, pipeline_version)
  VALUES
    ('{{ $json.event_type }}', '{{ $json.source }}', {{ $json.classified_entity_id }},
     $pl${{ $json.payload_json }}$pl$::jsonb, '{{ $json.payload_signature }}',
     'pending', '{{ $json.trace_id }}', {{ $json.parent_event_id }},
     '{{ $json.idempotency_key }}', '{{ $json.pipeline_version }}')
  ON CONFLICT (idempotency_key) WHERE idempotency_key IS NOT NULL
    DO NOTHING
  RETURNING id
```

to:

```sql
  INSERT INTO events
    (event_type, source, entity_id, payload, payload_signature,
     status, trace_id, parent_event_id, idempotency_key, pipeline_version)
  SELECT '{{ $json.event_type }}', '{{ $json.source }}', {{ $json.classified_entity_id }},
         $pl${{ $json.payload_json }}$pl$::jsonb, '{{ $json.payload_signature }}',
         'pending', '{{ $json.trace_id }}', {{ $json.parent_event_id }},
         '{{ $json.idempotency_key }}', '{{ $json.pipeline_version }}'
   WHERE NOT EXISTS (
     SELECT 1 FROM events WHERE idempotency_key = '{{ $json.idempotency_key }}'
   )
  RETURNING id
```

(The `SET LOCAL app.current_entity = 'all';` prefix and the `parent_done` / `audit` CTEs stay unchanged.)

- [ ] **Step 3: Push to the live workflow** via the n8n API (see "Critical mechanic" above), then mirror the change into `.claude/n8n-exports/email-pipeline.json`.

- [ ] **Step 4: Verify the checker clears**

Run: `python3 scripts/audit-invariants.py | grep INV-IDEMPOTENCY || echo CLEARED`
Expected: `CLEARED`.

- [ ] **Step 5: Smoke-test on a real event** — replay one `email.received` event through the pipeline and confirm the node returns a row and writes one `events` row (no duplicate, no error in n8n execution log).

- [ ] **Step 6: Commit**

```bash
git add .claude/n8n-exports/email-pipeline.json
git commit -m "fix(email-pipeline): events insert WHERE NOT EXISTS, not ON CONFLICT (F9)"
```

---

## Task 2: F6 — drop raw body_text fallbacks from AI-prompt paths

**Why:** AGENTS hard rule — model input must use `body_text_safe` (Presidio-sanitised). A `body_text_safe || body_text` fallback silently sends unredacted PII to the model whenever the safe field is empty. Three nodes do this.

**Files:**
- Modify: live workflows + repo copies:
  - `email-pipeline.json` node `Build Classification Prompt`
  - `gmail-ingest.json` node `Sign Payloads`
  - `nanny.json` node `Validate Event`
- Test: `scripts/audit-invariants.py` (INV-BODY-TEXT)

- [ ] **Step 1: Baseline**

Run: `python3 scripts/audit-invariants.py | grep INV-BODY-TEXT`
Expected: the three nodes above listed with "fallback defeats redaction".

- [ ] **Step 2: Remove each `|| body_text` fallback**

In each node's `jsCode`/prompt, change the pattern:

```js
const safe = raw.body_text_safe || raw.body_text || '';
```

to:

```js
// AGENTS: model input must be the redacted field only — no raw fallback.
const safe = raw.body_text_safe || '';
```

If a node legitimately needs *something* when `body_text_safe` is empty, the correct fix is to **re-run sanitisation** (call homeai-presidio), not to fall back to raw text. If the safe field is empty because Presidio failed, the node should mark the item for review, not prompt on raw PII.

- [ ] **Step 3: Push each workflow** via the n8n API and mirror into the repo exports.

- [ ] **Step 4: Verify**

Run: `python3 scripts/audit-invariants.py | grep INV-BODY-TEXT || echo CLEARED`
Expected: `CLEARED` (or only non-fallback advisory lines, if any).

- [ ] **Step 5: Commit**

```bash
git add .claude/n8n-exports/email-pipeline.json .claude/n8n-exports/gmail-ingest.json .claude/n8n-exports/nanny.json
git commit -m "fix(pipelines): drop raw body_text fallback in AI prompts (F6)"
```

---

## Task 3: F4 — make the dashboard's docker.sock mount read-only / proxied

**Why:** `build-dashboard` mounts `/var/run/docker.sock` read-write (compose:303). A web-facing container with RW socket access = effective host root. The dashboard only needs *read* access (container status, `docker stats`) plus the ability to run benchmark `exec`s.

**Files:**
- Modify: `docker-compose.yml:303` (+ add a socket-proxy service)
- Test: `scripts/audit-invariants.py` (INV-DOCKER-SOCK)

- [ ] **Step 1: Baseline**

Run: `python3 scripts/audit-invariants.py | grep INV-DOCKER-SOCK`
Expected: `docker-compose.yml:303`.

- [ ] **Step 2: Decide the access level the dashboard actually needs.**

Grep what it calls: `grep -nE "docker|/containers|/exec|sock" services/build-dashboard/main.py`.
- If it only reads status/stats → switch to `:ro` (Step 3a).
- If it needs `exec` for benchmarks → put a scoped **tecnativa/docker-socket-proxy** in front (Step 3b); RW on the raw socket is not acceptable for a web surface.

- [ ] **Step 3a: Read-only (if no exec needed)**

Change `docker-compose.yml:303` from:
```yaml
      - /var/run/docker.sock:/var/run/docker.sock
```
to:
```yaml
      - /var/run/docker.sock:/var/run/docker.sock:ro
```

- [ ] **Step 3b: Socket proxy (if exec needed)** — add a proxy service and point the dashboard at it instead of the raw socket:

```yaml
  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy:latest
    container_name: homeai-docker-proxy
    environment:
      CONTAINERS: "1"
      EXEC: "1"        # only if benchmarks need it
      POST: "1"
      IMAGES: "0"
      NETWORKS: "0"
      VOLUMES: "0"
      INFO: "1"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks: [ai-internal]
    restart: unless-stopped
```
Then in `build-dashboard`: remove the `docker.sock` volume and set `DOCKER_HOST: tcp://homeai-docker-proxy:2375`.

- [ ] **Step 4: Recreate the service** (image/static are baked — see the build-dashboard rebuild memory): rebuild if code changed, otherwise `docker compose up -d build-dashboard docker-socket-proxy`. Confirm the dashboard still renders container status.

- [ ] **Step 5: Verify**

Run: `python3 scripts/audit-invariants.py | grep INV-DOCKER-SOCK || echo CLEARED`
Expected: `CLEARED`.

- [ ] **Step 6: Commit**

```bash
git add docker-compose.yml
git commit -m "fix(dashboard): drop RW docker.sock; read-only/proxied access (F4)"
```

---

## Task 4: INV-ENTITY-LOCAL — convert bare `SET` to `SET LOCAL`

**Why:** `SET app.current_entity = …` (without `LOCAL`) persists on the connection. n8n's Postgres node uses a pooled connection, so the next workflow to grab that connection inherits the entity GUC — a cross-entity data-leak / wrong-scope risk. The `SET ROLE drops GUC defaults` memory makes this worse: a leaked `'all'` can over-expose. Affects gmail-ingest (6 nodes), caterbook/epos/pub-anomaly/telegram-bot read+write nodes.

**Files:**
- Modify: live workflows + repo copies for every node listed under INV-ENTITY-LOCAL
- Test: `scripts/audit-invariants.py` (INV-ENTITY-LOCAL)

- [ ] **Step 1: Baseline list**

Run: `python3 scripts/audit-invariants.py | grep INV-ENTITY-LOCAL`
Expected: the ~16 nodes across gmail-ingest, caterbook, epos, pub-anomaly, telegram-bot.

- [ ] **Step 2: In each flagged query, change `SET app.current_entity = '…';` to `SET LOCAL app.current_entity = '…';`**

Example — gmail-ingest `INSERT email.received`:
```sql
-- before
SET app.current_entity = '{{ $json.ai_entity_id }}';
-- after
SET LOCAL app.current_entity = '{{ $json.ai_entity_id }}';
```
For read-only nodes (`Find unprocessed …`, `Fetch stats`, `Compare to trailing window`) the same change applies — a leaked GUC affects subsequent reads too.

> Note: `SET LOCAL` only takes effect inside a transaction. n8n's Postgres "Execute Query" runs each query in its own implicit transaction, so a leading `SET LOCAL` in the same query string is in-scope. Verify in the n8n execution log that rows still return after the change (one node first, before doing all).

- [ ] **Step 3: Push workflows one at a time** via the n8n API; verify each still returns rows before moving on. Mirror into repo exports.

- [ ] **Step 4: Verify**

Run: `python3 scripts/audit-invariants.py | grep INV-ENTITY-LOCAL || echo CLEARED`
Expected: `CLEARED`.

- [ ] **Step 5: Commit**

```bash
git add .claude/n8n-exports/
git commit -m "fix(pipelines): SET LOCAL app.current_entity to stop GUC pool-leak"
```

---

## Task 5: F5 — route build-dashboard's direct Anthropic call through the gateway

**Why:** `services/build-dashboard/main.py:2713` POSTs `https://api.anthropic.com/v1/messages` directly, bypassing llm-router → no Presidio redaction, no £3/day budget accounting, no shared retry (the 529-storm protection from `lib/claude_call.py`). The `lib/README.md` already tracks the remaining raw-HTTP callers; this is one of them.

**Files:**
- Modify: `services/build-dashboard/main.py` (the `~2534–2720` block)
- Reference: `lib/claude_call.py`, `services/llm-router/main.py`
- Test: `scripts/audit-invariants.py` (INV-DIRECT-LLM)

- [ ] **Step 1: Baseline**

Run: `python3 scripts/audit-invariants.py | grep "INV-DIRECT-LLM.*build-dashboard"`
Expected: the build-dashboard line.

- [ ] **Step 2: Read the call site and the gateway contract**

Run: `sed -n '2700,2725p' services/build-dashboard/main.py` and check llm-router's request shape in `services/llm-router/main.py`.

- [ ] **Step 3: Replace the raw POST with a call to llm-router** (so budget/Presidio/retry apply). Replace the `client.post("https://api.anthropic.com/v1/messages", …)` block with a POST to the internal router endpoint, dropping the direct Vault key read (`_vault_read("anthropic")`) since the router holds the key:

```python
        # Route via llm-router so budget caps, Presidio redaction and the
        # shared retry policy apply (was a direct api.anthropic.com call).
        r = await client.post(
            "http://homeai-llm-router:8080/v1/messages",
            json={"model": model, "max_tokens": max_tokens, "messages": messages},
            timeout=120,
        )
```

If build-dashboard genuinely needs a path the router doesn't expose, the documented exception is to use the shared `lib/claude_call.py` wrapper (retry + budget hooks) rather than a bare `httpx.post`.

- [ ] **Step 4: Rebuild build-dashboard** (code is baked into the image) and confirm the feature that used this call still works end-to-end.

- [ ] **Step 5: Verify**

Run: `python3 scripts/audit-invariants.py | grep "INV-DIRECT-LLM.*build-dashboard" || echo CLEARED`
Expected: `CLEARED`. (The `bot-responder` INV-DIRECT-LLM warning is expected — it is the conversational bot and uses its own `claude_call.py` wrapper; document it as an accepted exception or add `bot-responder/responder.py` to the allow-list rationale.)

- [ ] **Step 6: Commit**

```bash
git add services/build-dashboard/main.py lib/README.md
git commit -m "fix(dashboard): route LLM calls via llm-router, not direct API (F5)"
```

---

## Task 6: F1 + F2 — superuser→scoped-role migration (SEPARATE PLAN, U151b)

**Why this is its own plan:** 7 services connect as `postgres` (BYPASSRLS), so RLS entity isolation is **not actually enforced today**. The fix is blocked on: V177 roles are `NOLOGIN`; `RLS_ENFORCE_SET_ROLE` is default-0 pending a grant-gap audit; `SET ROLE` drops `ALTER ROLE SET` GUC defaults (must set both GUCs). Until F1 lands, the F2 service-side missing-GUC warnings (`llm-router`, `wa-bridge`, etc.) are *latent* — they bite the moment RLS is enforced.

**Do not execute inline.** Write a dedicated plan covering, in order:
- [ ] Grant-gap audit: for each of the 7 services, enumerate every table/op it touches and the minimum grants a scoped role needs.
- [ ] Give the scoped roles `LOGIN` + store credentials in Vault (`secret/postgres-roles` is canonical).
- [ ] Swap each service DSN (compose:60,305,407,541,600,626,647) from `postgres` to its scoped role; rebuild/restart.
- [ ] Add `SET LOCAL app.current_entity` (and the realm GUC) to every service write path flagged by INV-ENTITY-GUC (`llm-router/main.py`, `wa-bridge/main.py`, etc.).
- [ ] Flip `RLS_ENFORCE_SET_ROLE=1` behind the existing canary, then full rollout.
- [ ] Verify: `python3 scripts/audit-invariants.py | grep -E "INV-PG-SUPERUSER|INV-ENTITY-GUC"` returns nothing.

---

## Task 7: Wire the checker in as a regression gate

**Why:** The whole point — catch the next violation when it is introduced, not months later.

**Files:**
- Reference: existing pre-push scan (`feedback_homeai_pre_push_scan`) and JOLY's crontab
- Modify: `.git/hooks/pre-push` (or the existing pre-push scan script), crontab

- [ ] **Step 1: Add to the pre-push scan** — append to the existing pre-push hook so a `FAIL` blocks the push:

```bash
python3 /home_ai/scripts/audit-invariants.py || {
  echo "Invariant audit failed — fix FAIL findings or override with --no-verify"; exit 1; }
```

- [ ] **Step 2: Add a daily cron** (JOLY's crontab, where the other ops jobs live) that runs the checker and Telegrams only on `FAIL` (quiet-unless-degraded, per the heartbeat-noise memory):

```cron
17 6 * * * cd /home_ai && python3 scripts/audit-invariants.py >/tmp/inv-audit.log 2>&1 || /home_ai/scripts/notify-telegram.sh "Invariant audit FAIL — see /tmp/inv-audit.log"
```

- [ ] **Step 3: Verify the gate** — introduce a throwaway `ON CONFLICT` on an events insert in a scratch copy, confirm exit code 1, then revert.

- [ ] **Step 4: Commit**

```bash
git add scripts/audit-invariants.py
git commit -m "chore(audit): invariant checker + pre-push/cron regression gate"
```

---

## Self-review

- **Spec coverage:** F9 (T1), F6 (T2), F4 (T3), INV-ENTITY-LOCAL (T4), F5 (T5), F1/F2 (T6, separate plan), regression gate (T7). F3/published-ports resolved as not-a-finding (tailnet binds) — no task needed. F7 (n8n SQL interpolation) and F8/F10 (perf) are not invariant violations and are out of scope for this remediation; track them separately.
- **Verification:** every task uses `scripts/audit-invariants.py` as its pass/fail oracle plus a runtime smoke test.
- **Ordering:** T1–T5 are independent and safe in any order; T6 is the large blocked item; T7 should land last so the gate reflects a clean (or known-WARN) baseline.
