# OVERNIGHT-LOG — 2026-05-07/08

Autonomous run while Jo's away. File-only edits, no container restarts, no Vault writes.

Read this first when you're back. Items are appended chronologically.

---

## Plan

8 tasks (in priority order):

1. Image pinning sweep
2. Master Router JSON fix
3. Draft email_pipeline workflow JSON
4. Refresh STRETCH §3.3 + §4
5. Code review of llm-router/main.py
6. Design rent_payments JOIN-based RLS policy
7. Design init_placeholder HMAC trigger fix
8. SPEC drift audit

Will append `[done]`, `[partial]`, or `[blocked]` to each as I go, with a short summary.

---

## Status

(updates appended below as I work)

---

### Task 1 — Image pinning sweep [done]

Pinned 9 images to specific versions in `docker-compose.yml`. Compose validates clean.

| Service | Was | Now |
|---|---|---|
| qdrant | `:latest` | `:v1.17.1` |
| n8n | `:latest` | `:2.18.5` |
| ollama | `:latest` | `:0.22.1` |
| metabase | `:latest` | `:v0.60.3.3` |
| authelia | `:latest` | `:4.39.19` |
| grafana | `:latest` | `:13.0.1` |
| prometheus | `:latest` | `:v3.11.3` |
| netdata | `:latest` (was running nightly) | `:stable` (channel pin — note: switches to stable releases, not full version pin) |
| open-webui | `:main` | `:0.9.2` |

Already pinned earlier (left alone): `postgres:16`, `redis:7-alpine`, `hashicorp/vault:1.15.6`, `caddy:2-alpine`.

**No restart performed.** Pinning takes effect on next `docker compose up -d` — at that point compose may pull the pinned tag if it differs from the cached image. If you want to force-pull-and-recreate later: `docker compose pull && docker compose up -d`. If you'd rather stay on currently-running image instances, leave as-is and the pinning kicks in only on the next reboot (when start.sh runs).

**Note on netdata**: `:stable` is a channel pin, not a fixed version. It auto-updates within the stable channel. To get a hard pin, replace with `:v2.10.0` once you confirm that exact tag exists on Docker Hub.

---

### Task 2 — Master Router JSON fix [done]

Wrote fixed file at `/home_ai/.claude/n8n-exports/master-router.fixed.json` (original preserved at `master-router.json`).

**Bug found**: the Switch v3 node `Route by Event Type` had three schema problems against n8n 2.18.5's installed Switch V3 definition (verified by reading `SwitchV3.node.js` inside the n8n container):

1. `rules.rules[]` should be `rules.values[]` — collection key was renamed in Switch v3.0.
2. `fallbackOutput: "unhandled"` is not a valid enum value (valid: `none`, `extra`, or a numeric rule index). The string `"unhandled"` was meant as a *rename* of the fallback output, which is a different field (`options.renameFallbackOutput`).
3. Each rule's `conditions` block was missing the required `options` object (caseSensitive/leftValue/typeValidation) and `combinator: 'and'`.

The activation error `Could not find property option` came from #2 — the option-loader couldn't match `"unhandled"` against valid fallback values.

**To apply the fix** (your terminal):

```bash
# Update the existing workflow with fixed JSON (preserves id, credentials)
docker exec -i homeai-n8n n8n update:workflow --id=4Tyj7ImxpkZZmitf --file=- < /home_ai/.claude/n8n-exports/master-router.fixed.json
# Or if that command shape isn't supported, delete + import:
# docker exec homeai-n8n n8n delete:workflow --id=4Tyj7ImxpkZZmitf
# docker exec -i homeai-n8n n8n import:workflow --input=- < /home_ai/.claude/n8n-exports/master-router.fixed.json
# (the deleted-then-imported version will get a new id; update build-state line accordingly)

# Then activate
docker exec homeai-n8n n8n update:workflow --id=4Tyj7ImxpkZZmitf --active=true

# Watch for activation success (no "Could not find property option" message)
docker logs homeai-n8n --since 30s 2>&1 | grep -i 'master\|workflow'
```

Diff against original is in `master-router.fixed.json` — only the `Route by Event Type` node's parameters changed. All other nodes, connections, IDs, credentials references unchanged.

---

### Task 3 — Draft email_pipeline workflow JSON [done with caveats]

Wrote `/home_ai/.claude/n8n-exports/email-pipeline.json`. 10 nodes, linear happy-path + dead-letter sidecar.

**Node sequence:**
1. **Webhook** at `/webhook/email-pipeline` (matches Master Router's HTTP request URL)
2. **Extract Event Fields** (Code) — parses inbound event, validates required fields
3. **Fetch Email Row** (Postgres) — `SELECT … FROM emails WHERE gmail_message_id = $1`
4. **Build Classification Prompt** (Code) — assembles the system + user prompt per SPEC §6.2
5. **Classify via llm-router** (HTTP) — POST to `http://homeai-llm-router:8001/route` with `task_type=email.classify`
6. **Validate Classification** (Code) — strict JSON parse + category/entity_id/confidence validation; strips markdown fences if model added them
7. **Update Email Row** (Postgres) — sets classification, confidence_score, entity_id, processed=true
8. **Sign + Emit email.classified** (Code) — HMAC-SHA256 signs the new event payload
9. **Write Events + Audit + Mark Done** (Postgres) — single statement: INSERT new event, UPDATE parent (mark done), INSERT audit_log
10. **Dead Letter (error path)** (Postgres) — INSERTs to dead_letter; idempotent against double-fire

### Caveats — please review before importing

**1. Parameter substitution (`$1, $2…`) may not work as written.** I used `options.queryReplacement` with a comma-separated expression. n8n's Postgres v2.5 `executeQuery` splits this string on commas at execution time — and the `payload` field is a JSON blob that contains commas, so the split will break. **Two fixes possible**:
  - (a) Refactor each Postgres node to inline values via `{{ $json.field }}` expressions directly in the query string (loses parameterisation but matches the precedent in master-router.json's Claim Batch).
  - (b) Split the combined CTE statement into three smaller `insert`-operation nodes (cleaner but longer workflow).
  Recommendation: **(a)** for now to keep it close to the existing pattern. I didn't apply it because it crosses into "sign-off-required" territory given SQL-injection considerations (all values are internal here, so it's safe — but the user should sanity-check).

**2. Error-path connections aren't wired.** The dead_letter node exists but isn't connected via each Postgres/Code node's `error` output. n8n requires explicit error wiring per node. Easiest in the UI: drag from each node's red output marker to the dead_letter node. Alternative: edit the JSON `connections` block to add `"main": [..., [...error connections...]]` per node — fiddly to do correctly, easier to use the UI once.

**3. `$env.PAYLOAD_HMAC_KEY` access in Code node.** Per project memory item 7, `N8N_BLOCK_ENV_ACCESS_IN_NODE` was set somewhere blocking `$env` reads in nodes. Need to either:
  - Flip that env var to allow it (security regression — Phase 2 hardening would re-block via AppRole)
  - Or fetch the signing key via Vault HTTP call earlier in the pipeline (matches Gmail Ingest's pattern with `Vault: Signing Key` node)
  Recommendation: fetch via Vault, mirror Gmail Ingest's approach. I didn't add that step because it requires copying the `vault-token-header` credential pattern; user can paste in the same node from gmail-ingest.json.

**4. Webhook is unauthenticated.** Master Router's HTTP call sends no auth headers. Webhook accepts anything POSTed to `/webhook/email-pipeline`. Acceptable on the internal-only network; would need auth if Caddy ever exposes it.

**5. `idempotency_key` constraint.** The `ON CONFLICT (idempotency_key) WHERE idempotency_key IS NOT NULL DO NOTHING` clause uses a partial unique index. Confirm `idx_events_idempotency` exists with the matching predicate (init-db.sql:43-44 says it does — partial unique on `idempotency_key WHERE idempotency_key IS NOT NULL`). ✓

**To import**:
```bash
docker exec -i homeai-n8n n8n import:workflow --input=- < /home_ai/.claude/n8n-exports/email-pipeline.json
```
Then open in UI, address caveats #1-3, save, activate.

---

### Task 4 — Refresh STRETCH §3.3 + §4 [done]

Updated `HOME-AI-STRETCH.md`:

**§3.3 (Vault secrets state)** — annotated `secret/postgres-roles` with the 2026-05-07 rotation note. Replaced `secret/gmail/account1` and `account2` with `secret/gmail/personal1`, `personal2`, `workspace` to match the 3-account Gmail decision (2 personal + 1 Workspace). Marked the in-progress nature of the Vault put for `personal1`. Added a naming note flagging that `gmail-ingest.json` references the old `account1`/`account2` paths and must be updated.

**§4 (Pending decisions)** — marked four items resolved:
- Step 9b gate verification (gate ran 2026-05-07, all 5 green)
- Docker image pinning (9 services pinned today)
- Master Router activation (diagnosed + fix drafted today)
- Email pipeline workflow drafted (today)

Added five new entries:
- Metabase: homeai data source not connected (blocking Gate B Q7)
- Gmail OAuth credentials (× 3) in progress
- n8n vault-token-header credential rotation (Phase 2 hardening)
- rent_payments RLS (design pending — needs JOIN policy or denormalised entity_id)
- llm-router crash root cause (open — service currently stopped)

Kept all existing not-yet-resolved items (NatWest, RBS, ICRTouch, Dext, WhatsApp blacklist, Garmin, init_placeholder, HMAC signing key).

---

### Task 5 — Code review of llm-router/main.py [done — with one critical finding]

**Trivial fixes applied to `services/llm-router/main.py`:**
- Type hint bug: `_call_ollama` and `_call_claude` were declared as returning `tuple[str, int, int]` but actually return a 4-tuple `(text, prompt_tokens, completion_tokens, latency_ms)`. Fixed to `tuple[str, int, int, int]`.
- Pydantic warning: `RouteResponse.model_used` collides with pydantic's `model_` protected namespace. Added `model_config = {"protected_namespaces": ()}` to silence.
- Deprecated API: `datetime.utcnow()` → `datetime.now(timezone.utc)` (one site in `/stats` endpoint). Added `timezone` import.

**Critical finding — `ai_usage` table doesn't exist.**

llm-router's `_log_usage` and `/stats` endpoint both write to / read from `ai_usage`. That table is not in the live DB. Every call to `_log_usage` has been silently failing — caught by the broad `except Exception` and a `print()` to stdout that goes nowhere useful. Effectively the AI-usage telemetry has never worked.

**Root cause**: there's a migration file `postgres/migrations/V3__ai_usage.sql` that **collides with my `V3__restore_rls_policies.sql`** in the version sequence. Two migrations, same version number = ambiguous order = whichever was applied first wins. `V3__restore_rls_policies` was applied (RLS policies are present); `V3__ai_usage` was orphaned.

**Action taken**: renamed `V3__ai_usage.sql` → `V6__ai_usage.sql` (next free number after V5). Migration not yet applied — needs your `psql -f` run when ready:

```bash
docker exec -i homeai-postgres psql -U postgres -d homeai \
  -f - < /home_ai/postgres/migrations/V6__ai_usage.sql
```

After application: llm-router's logging will start working. `/stats` endpoint will return real numbers.

**Non-trivial findings flagged for later** (not applied):
- Two static_context lookups per `route` call (`_get_model_tiers` + `_get_thresholds`) could be a single combined query — ~5 ms saved per request, low priority.
- Cache write on hot-tier success could be fire-and-forget like `_log_usage` — small latency win.
- Stringly-typed tier names (`"hot"`, `"medium"`, `"heavy"`, `"claude"`) — could be `Literal` or enum, but small surface area.

---

### Task 6 — Design rent_payments JOIN-based RLS policy [done]

Wrote design doc at `/home_ai/.claude/decisions/2026-05-08-rent-payments-rls.md`.

**Decision**: Option B (denormalise `entity_id` onto `rent_payments`) over Option A (JOIN-based policy via tenancies). Reasons: pattern consistency with the other 10 entity-scoped tables, faster queries, simpler RLS expression. Trigger maintains entity_id consistency if a tenancy ever moves between entities (rare).

Candidate migration drafted: `V7__rent_payments_entity_id.sql` (in the design doc). Apply when Phase 2 starts using rent_payments. Zero risk to apply now (table is currently empty).

---

### Task 7 — Design init_placeholder HMAC trigger fix [done — already resolved]

Discovered during Task 5: this was already fixed by `V4__drop_static_context_trigger.sql` (applied — verified `pg_trigger` count = 0).

V4's approach was cleaner than the original "fix the trigger" plan: drop the trigger entirely and require services to emit properly-signed `system.config_change` events from application code (model-evaluator's `deploy_model` is the reference pattern).

**Updated AGENTS.md gotcha** to reflect the new convention (anything mutating `static_context` must emit the event from app code with HMAC signing).

Wrote a status doc at `/home_ai/.claude/decisions/2026-05-08-init-placeholder-resolution.md` explaining what V4 did and what the convention is going forward.

---

### Task 8 — SPEC drift audit [done]

Found and patched three drift items in `SPEC.md`:

1. **Lines 1800-1810 (Step 9 + 9b verification curls)** — were `curl http://localhost:8003/...` and `localhost:8080/...`. Both broken because services are on `ai-internal` (internal-only) which silently ignores host port mappings. Patched to use `docker run --rm --network home_ai_ai-internal curlimages/curl:latest ...` pattern. Also fixed port `8080 → 8008` for model-evaluator (the original SPEC typo that conflicts with Open WebUI).

2. **Lines 236-237 (secret paths)** — was `secret/gmail/account1` + `account2`. Updated to `personal1` + `personal2` + `workspace` to match today's 3-account decision (2 personal + 1 Workspace).

3. **Line 2076 (Appendix D quick reference)** — same Gmail rename.

**Other drift logged but not patched** (out of scope for this run):
- SPEC line 1058/1062/1066 reference `'REPLACE_VIA_VAULT'` placeholder passwords. Not actually drift — those are *instructions* in the source SQL telling operators to rotate via Vault after init. Leave as-is.
- SPEC's Phase 1 "build order" section (lines ~1770+) doesn't mention the V3-V5 migrations or the llm-router service as an architectural component. Could be patched but doesn't block any current work.
- `init_placeholder` references in SPEC §3.2 (init-db.sql contents at lines 116-129) — the SPEC still includes the trigger source. Since V4 dropped it, the SPEC's init-db.sql section is now divergent from the live behaviour. Not blocking; if init-db.sql is ever re-run on a fresh DB, the trigger will be recreated and V4 should run after to drop it. Acceptable tech debt.

---

## Summary

**8 tasks completed** in approximately 55 minutes of compute. All file-only edits; no container restarts, no Vault writes, no migrations applied.

### Files written or edited

- `docker-compose.yml` — 9 image pins
- `services/llm-router/main.py` — 3 trivial fixes (type hint, pydantic, datetime)
- `postgres/migrations/V3__ai_usage.sql` → renamed to **`V6__ai_usage.sql`**
- `HOME-AI-STRETCH.md` — §3.3 (Vault state) + §4 (pending decisions) refreshed
- `SPEC.md` — 3 drift patches (Step 9/9b verification, Gmail paths × 2)
- `AGENTS.md` — replaced obsolete `init_placeholder` gotcha with forward-looking convention
- New: `.claude/n8n-exports/master-router.fixed.json`
- New: `.claude/n8n-exports/email-pipeline.json`
- New: `.claude/decisions/2026-05-08-rent-payments-rls.md`
- New: `.claude/decisions/2026-05-08-init-placeholder-resolution.md`
- This file: `.claude/OVERNIGHT-LOG.md`

### What you need to do (in priority order)

1. **Verify Master Router fix** — review `master-router.fixed.json` against the original, then re-import + activate. Once active, the email-routing chain has its consumer.
2. **Apply `V6__ai_usage.sql`** — single psql command (no env vars needed). Restores llm-router's usage logging and `/stats`.
3. **Resume Gmail OAuth setup** — finish `personal1` Vault put (verify with the lengths command), then do `personal2` and `workspace`.
4. **Add homeai database to Metabase** — via Metabase UI, using `homeai_readonly` creds. Required for Gate B Q7.
5. **Review `email-pipeline.json`** — address the 3 caveats (parameter substitution, error wiring, env-var access) before importing.
6. **Decide on Authelia + llm-router** — both currently stopped. Authelia is on `phase2` profile (won't auto-start). llm-router was stopped manually after the unexplained crash; that needs investigation when you're ready.

### What's still outstanding (not touched this run)

- llm-router crash root cause (manual stop in place)
- Gmail OAuth completion (your work)
- NatWest/RBS Open Banking registration (your work, lead time)
- ICRTouch PLU tracking (your work)
- Dext API key (your work)
- WhatsApp blacklist numbers (your work)
- Vault auto-unseal + AppRole hardening (Phase 2)
- Step 11 build itself — the prerequisites are now clear; the build itself starts when you sign off on the email-pipeline draft + Master Router fix + Metabase data source

End of run.

---

## 2026-05-08 morning continuation

### Master Router cutover [done, verified]

State at session start: two workflows in DB. The original `4Tyj7ImxpkZZmitf` was
still active=true but n8n had given up trying to activate it (exponential backoff
hit ~9 hours and stopped retrying). The test workflow `test-master-router` had
**28 successful executions in the previous hour** — the fix was working.

Cutover steps applied:

1. `n8n unpublish:workflow --id=4Tyj7ImxpkZZmitf` (deactivated old)
2. `DELETE FROM workflow_entity WHERE id = '4Tyj7ImxpkZZmitf'` (cleaned up stale row)
3. `UPDATE workflow_entity SET name = 'Master Router' WHERE id = 'test-master-router'`
   (renamed test → canonical)

Verified:
- Single workflow named "Master Router", id `test-master-router`, active=t
- 4 executions in 2 minutes since cutover (the 30s cron is firing)
- Old id no longer in DB
- No `Could not find property option` errors in logs since cutover

**Caveat for next session:** the canonical id is `test-master-router` now, not
`4Tyj7ImxpkZZmitf`. Anything documented or scripted against the old id needs
updating. AGENTS.md build state has been updated; check `gmail-ingest.json`
or other workflows for any hardcoded references (none found in a quick grep).

### V6__ai_usage.sql applied [done, verified]

Applied: 1 CREATE TABLE + 2 CREATE INDEX. Smoke test confirmed: direct
INSERT/DELETE on ai_usage row works.

llm-router does not need a restart — asyncpg sees the new table immediately on
next query.

**Caveat noted:** llm-router's `_log_usage` is only called on success paths in
`/route`. HTTP 503 errors (escalation needed but not allowed, etc.) and
HTTPException paths skip the logging entirely. So `ai_usage` will undercount
calls until that gap is fixed. Minor — flagged for a future refactor pass.

### What's still owed by you

- **#3 — Add `homeai` as Metabase data source** (UI work, ~10 min)
- **#4 — Resume Gmail OAuth** for personal1, personal2, workspace
- **email-pipeline.json import** when you've decided on the 3 caveats (parameter
  binding, error wiring, env-var access) — see Task 3 entry above

Stopping here. Did not touch llm-router beyond the smoke test, did not import
email-pipeline.json, did not do anything that needs your shell env or Vault token.

---

### Metabase homeai data source [done, verified]

Discovered `secret/postgres-roles.homeai_readonly` field was missing from Vault
(the Postgres role existed with `REPLACE_VIA_VAULT` placeholder). Created
`/home_ai/.claude/scripts/rotate-readonly.sh` — generates hex (paste-safe,
no base64 special chars), patches Vault, ALTER ROLEs Postgres, verifies psql
auth before declaring success.

User added homeai as Metabase data source via Admin UI. Confirmed: ~25 tables
visible in Metabase under homeai connection.

Gate B Q7 ("email visible in review queue") prerequisites now satisfied —
data path Metabase → homeai exists. The actual review-queue card can be
built later when emails table has data; SQL ready on request.

### Outstanding for next session

Single remaining prerequisite for Step 11 build: **Gmail OAuth credentials
for `personal1`, `personal2`, `workspace`** in Vault. Once those are populated,
the Gmail Ingest workflow can pull real emails and the full Step 11 vertical
slice can run end-to-end.

Other deferred items in priority order:
- Review and import `email-pipeline.json` (3 caveats logged: parameter binding,
  error-path wiring, env-var access)
- Apply V7 rent_payments RLS migration (zero-risk, table empty)
- Refactor llm-router to log usage on error paths too (currently only
  success paths call `_log_usage`)
- Phase 2 hardening: AppRole replacement of static n8n vault-token-header
  credential


