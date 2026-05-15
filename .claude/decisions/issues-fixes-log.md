# Issues & Fixes Log

Append-only record of build issues and how they were resolved.
Format: most recent first. One entry per issue.

---

## 2026-05-01 — Metabase crash-loop on first boot

**Symptom:** `homeai-metabase` crash-looping with
`ERROR: permission denied for schema public` while running Liquibase
CREATE TABLE for its own metadata (`databasechangelog`).

**Root cause:** Metabase was pointed at the *application* database
(`MB_DB_DBNAME=homeai`) as the *read-only* role
(`MB_DB_USER=homeai_readonly`). Postgres 15+ revokes CREATE on `public`
from the PUBLIC role by default, so Liquibase couldn't bootstrap.
Granting CREATE to `homeai_readonly` would have defeated the RLS /
least-privilege model.

**Fix:** Created dedicated `metabase_app` database + role with full
ownership of its own `public` schema. Pointed Metabase at it via
`MB_DB_DBNAME=metabase_app`, `MB_DB_USER=metabase_app`.
The `homeai` database is added separately as a Metabase Data Source
in the UI, queried via `homeai_readonly`.

**Artefacts:**
- `postgres/migrations/V2__metabase_db.sql` (idempotent)
- `docker-compose.yml` Metabase env block updated
- New Vault secret: `secret/postgres-roles/metabase_app`

---

## 2026-05-01 — psql `:'var'` substitution fails inside `$$…$$` blocks

**Symptom:** Initial draft of `V2__metabase_db.sql` used a `DO $$ … $$`
PL/pgSQL block to conditionally `CREATE ROLE … PASSWORD :'pwd'`.
psql does not perform variable substitution inside dollar-quoted
strings — the literal `:'pwd'` would have been sent to the server.

**Fix:** Generate the SQL at the top level using
`format('CREATE ROLE … PASSWORD %L', :'pwd')` piped through `\gexec`,
guarded by `WHERE NOT EXISTS (…)` for idempotency.

**Convention going forward:** any migration that needs a psql variable
substituted into a runtime SQL statement must do it at the top level,
not inside a DO block.

---

## 2026-05-01 — Vault unseal keys exposed in chat transcript

**Symptom:** Three of five Shamir unseal keys were pasted into a
Claude Code conversation while following a post-reboot runbook.

**Fix:** Rekey performed (`vault operator rekey -init -key-shares=5
-key-threshold=3`); five new shares generated and stored offline.
Root token rotated via `vault operator generate-root` using the new
shares. Old root token revoked by accessor.

**Operational outcome:** The three exposed keys are now invalid; only
the new shares can unseal Vault. Tailscale-only network exposure
limited blast radius during the window of compromise.

---

## 2026-05-02 — RLS policies missing on 7 of 10 tables

**Symptom:** Model-evaluator deploy endpoint failed with
`InsufficientPrivilegeError: new row violates row-level security policy
for table "events"` even with `SET LOCAL app.current_entity = 'all'`.

**Root cause:** `pg_policies` showed zero policies on `events` (and 6 other
RLS-enabled tables: `emails, invoices, bank_transactions, rent_payments,
documents, cashflow_forecast`). `rls-policies.sql`'s DO block had partially
executed at init time — only 3 of 10 tables got their `entity_isolation`
policy. RLS-enabled with no policy = deny-all, which blocked every
non-superuser write.

**Implication:** Gate A's "test event → events_2026_05" pass was a phantom
(test was run as `postgres` superuser, bypassing RLS).

**Fix:** `V3__restore_rls_policies.sql` re-applies the 6 missing policies
(rent_payments excluded — has no entity_id; tracked separately).

---

## 2026-05-02 — DSN URL parse fails when base64 password contains `/`

**Symptom:** `asyncpg.ValueError: invalid literal for int() with base 10:
'KHs26VMeVMTQmxPc'` at pool creation.

**Root cause:** `openssl rand -base64 32` outputs use the `/` char
(URL-unsafe). The compose interpolation embedded the password into a DSN
URL: `postgresql://homeai_pipeline:KHs26V…/abc@postgres:5432/homeai`.
The `/` terminated the authority section early, so asyncpg parsed
`KHs26V…` as the *port*, hence the int-parse error.

**Fix:** Changed compose env to pass connection params as separate vars
(`POSTGRES_HOST/PORT/USER/PASSWORD/DB`) and use asyncpg's keyword args
instead of a DSN. URL-encoding doesn't help because compose interpolation
isn't URL-aware.

**Convention:** Never put `openssl rand -base64`-shaped passwords into a
URL-shaped DSN. Always split into individual conn params.

---

## 2026-05-02 — Missed `SET LOCAL` in own service code

**Symptom:** Build rule says "ALWAYS prepend SET LOCAL app.current_entity
before any PostgreSQL write." First version of `model-evaluator/main.py`
mentioned this in its design plan but didn't implement it. Deploy endpoint
hit RLS deny on the `static_context_change` trigger's downstream INSERT.

**Fix:** Added `SET LOCAL app.current_entity = 'all'` at the start of every
write transaction in `_scan`, `deploy_model`, `_benchmark`. Later (today,
2026-05-07) extracted to a `_set_system_entity(conn)` helper.

**Lesson:** Plan-vs-implementation drift is sneaky. Worth a checklist item.

---

## 2026-05-02 — SPEC §4.3-style `localhost:8008` curls cannot work

**Symptom:** Step 9b verification gate as written in SPEC says
`curl http://localhost:8008/api/...`. Connection refused from host.

**Root cause:** `ai-internal` network has `internal: true` in compose.
Docker silently ignores port-to-host mappings on services that are *only*
on internal-only networks. Both `model-evaluator` and `pdfplumber-service`
have this constraint; pdfplumber's gate also wouldn't have worked.

**Fix for verification:** Use a one-off curl container attached to the
same internal network:
`docker run --rm --network home_ai_ai-internal curlimages/curl:latest …`

**SPEC patch:** §4.3 example query has been updated to include the
required `SET LOCAL`; the host-vs-container-curl gap should also be
fixed in the SPEC at the next pass.

---

## 2026-05-03 — RLS policy `::int OR ='all'` pattern errors on cast

**Symptom:** Original `rls-policies.sql` used
`(entity_id = current_setting(…)::int OR current_setting(…) = 'all')`.
PG does *not* short-circuit boolean OR reliably across this expression —
when `app.current_entity = 'all'`, the `'all'::int` cast raises before the
right-hand side can evaluate.

**Fix:** `V5__rewrite_rls_policies.sql` rewrote all policies as a CASE
expression that explicitly handles the `'all'` and integer cases before
casting. `rls-policies.sql` source patched to match (so fresh inits don't
re-introduce the bug). Live DB carries V5; smoke-tested with all 10
policies.

**Note:** `V3__restore_rls_policies.sql` still contained the old broken
pattern in its `CREATE POLICY` template until 2026-05-07 — patched to
match V5 form so a fresh init through V3 produces correct policies.

---

## 2026-05-05 — `homeai_pipeline` had `REPLACE_VIA_VAULT` placeholder password

**Symptom:** n8n unable to connect to Postgres after a recreate.

**Root cause:** `rls-policies.sql:36` creates the role with the literal
placeholder `'REPLACE_VIA_VAULT'`. Comment on line 35 says to update via
Vault after init. That post-init step had been missed.

**Fix:** `ALTER ROLE homeai_pipeline PASSWORD '<value-from-vault>'`.

---

## 2026-05-06 — Master Router workflow imported with static Vault token

**Symptom:** Step 10 imported `master-router.json` via n8n CLI. The
`vault-token-header` n8n credential (id `0wPA4DCDuehPC9Mf`,
type `httpHeaderAuth`) holds a *static* Vault service token used by
`Fetch Vault Keys` and `Fetch Anthropic Key` nodes. `N8N_BLOCK_ENV_ACCESS_IN_NODE`
prevented `$env.VAULT_TOKEN` from being read inside Code nodes.

**Status:** Not a bug per se — interim solution. Phase 2 hardening must
replace this with an AppRole-issued token: (a) issue scoped Vault token
via AppRole, (b) update n8n credential, (c) remove `VAULT_TOKEN` env var
from n8n container. Tracked as deferred item in project memory.

---

## 2026-05-07 — Postgres password regressed to NULL via empty-fetch fix script

**Symptom:** model-evaluator + llm-router crash-looping with
`InvalidPasswordError`. Investigation found `homeai_pipeline.rolpassword IS
NULL` in `pg_authid`. Empty-string TCP login worked via psql (some local
auth method?) but asyncpg's SCRAM negotiation rejects.

**Root cause:** Fix script earlier in the session ran:
```
PW=$(docker exec -e VAULT_TOKEN homeai-vault \
       vault kv get -field=homeai_pipeline secret/postgres-roles)
docker exec -i homeai-postgres psql -U postgres -d homeai \
       -c "ALTER ROLE homeai_pipeline PASSWORD '$PW';"
```
The user's session `VAULT_TOKEN` lacked write/read scope on
`secret/postgres-roles`, returning empty. Empty `$PW` → `ALTER ROLE …
PASSWORD ''` → role password set to NULL.

**Fix:** Generated fresh strong password with `openssl rand -base64 32`,
applied to Vault (using a write-capable token), to the role, and to
container env in a single shell session.

**Lesson:** Any password-fetch script must fail loudly when the field is
empty. The `vault_kv_field` helper in `start.sh` already does this
(`jq -er` exits non-zero on null). Ad-hoc one-shot scripts must do the
same — never blindly use `$PW=""` to ALTER a role.

---

## 2026-05-07 — Master Router workflow fails to activate

**Symptom:** n8n logs show repeating
`Error: Could not find property option` /
`Activation of workflow "Master Router" (4Tyj7ImxpkZZmitf) did fail with
error … retry in 256 seconds`.

**Status:** New finding from Item 2 of comprehensive review run. Not
investigated; deferred to its own session. Likely cause: a node's
configuration references a credential or property option that no longer
exists (credential id refresh `iTuuNfsqHY49MGhk` from Step 10 may have
left a stale reference somewhere in the JSON).

---

## 2026-05-08 — Master Router Switch v3 schema mismatch (resolved)

**Symptom:** Continuation of 2026-05-07 finding. `Could not find property
option` from `getNodeParameters` during workflow activation.

**Root cause:** Three bugs in the Switch v3 `Route by Event Type` node:
1. `rules.rules[]` should be `rules.values[]` (collection key renamed in Switch v3.0).
2. `fallbackOutput: "unhandled"` is not a valid enum value (valid: `none`,
   `extra`, or numeric rule index). The string was meant as a rename of the
   fallback output, which is a different field (`options.renameFallbackOutput`).
3. Each rule's `conditions` was missing `options` block (caseSensitive,
   leftValue, typeValidation) and `combinator: 'and'`.

**Fix:** Rewrote the Switch node parameters in `master-router.fixed.json`,
deleted the old workflow, imported as test, renamed to canonical Master
Router. Workflow id changed: `4Tyj7ImxpkZZmitf` → `test-master-router`.

---

## 2026-05-08 — Anthropic API key + signing key exposed in chat (rotated)

**Symptom:** A 3-line diagnostic command piped through `vault kv get -field`
printed the Anthropic API key and the payload_hmac_key to terminal. User
shared the output, transcript captured both secrets.

**Fix:**
- Anthropic key revoked + regenerated in Anthropic console; new key stored
  in `secret/anthropic`.
- Signing key + redis password rotated via
  `/home_ai/.claude/scripts/rotate-signing-and-redis.sh` (hex output —
  paste-safe, no base64 special chars).

**Convention added to feedback memory** (feedback_homeai.md): Never use
diagnostic commands that print secret values to terminal. Use `vault kv list`
or `vault kv metadata get` for "exists?" checks. Use `wc -c`/`length` for
"shape?" checks. Never `vault kv get -field=…` followed by sharing output.

---

## 2026-05-08 — n8n stored Postgres credential drifted from role password

**Symptom:** Master Router and Watchdog workflows started failing with
`password authentication failed for user "homeai_pipeline"` after a routine
postgres password rotation. n8n's own DB connection (used for storing
executions) kept working — confusing because half of n8n appeared healthy.

**Root cause:** n8n credentials are stored encrypted in n8n's own DB (in
`credentials_entity`), separate from the container env
`DB_POSTGRESDB_PASSWORD`. The container env is refreshed on every
`docker compose up` via start.sh's secret fetch. The stored credential is
NOT — it stays at whatever was set when the credential was last edited
(via UI). Any postgres password rotation creates drift.

**Fix:** Updated the credential via n8n UI (Settings → Credentials →
HomeAI Postgres → paste new password → save). The CLI `n8n
import:credentials` silently no-ops when the credential id already exists,
so it can't be used for in-place updates.

**Prevention added to start.sh:** new `check_n8n_credential_drift()` step
compares `N8N_DB_PASSWORD` length to the stored credential's password
length. Warns loudly on mismatch with explicit UI fix instructions.

**Phase 2 hardening:** AppRole + dynamic credentials would eliminate this
class of drift entirely.

---

## 2026-05-08 — Master Router IF "[object Object]" + JSONB extraction (resolved)

**Symptom:** After fixing the Switch v3 bug, Master Router still failed
every execution at the `System Active?` IF node:
`Wrong type: '[object Object]' is an object but was expecting a string`.

**Root cause #1:** The seed value of `static_context.system.state` is a
JSONB object: `{"state": "running", "paused_at": null, "paused_reason": null}`.
The Postgres v2.5 node returned the JSONB column to n8n as a JS object.
The IF node compared `$json.value` against `'active'` — strict-type-checked,
saw object not string, threw.

**Root cause #2:** The IF condition expected `$json.value === 'active'`
but the seeded state value was `'running'`, not `'active'`.

**Fix:** (a) Updated `Kill Switch Check` query to extract the state field
as text via `value->>'state' AS state` so n8n receives a string. (b) Updated
IF condition to `$json.state === 'running'`.

---

## 2026-05-08 — Workflow_history vs workflow_entity drift (resolved)

**Symptom:** Direct `UPDATE workflow_entity SET nodes = ...` for Master
Router didn't take effect. Activation logs showed success; executions kept
using the old config.

**Root cause:** n8n stores TWO copies of every workflow: a draft
(`workflow_entity.nodes`) and one or more published versions
(`workflow_history.nodes`). The active workflow executes the version
referenced by `workflow_entity.activeVersionId`. Direct DB writes to
`workflow_entity.nodes` only update the draft; the editor UI shows the
draft, but the running engine uses the published version.

**Fix:** Update both rows. Specifically, `UPDATE workflow_history SET
nodes = … WHERE versionId = (SELECT activeVersionId FROM workflow_entity
WHERE id=…)` — that's the version the engine actually runs.

**Convention added to feedback memory:** Workflow patches via DB must
target workflow_history (the active version). `n8n publish:workflow`
copies draft → new published version, but isn't reliable for in-place
edits. UI is the safest path.

---

## 2026-05-15 — `vendor_invoice_inbox.category_canonical` is a STORED generated column (can't INSERT)

**Symptom:** First u78-ingest-utility.py run errored with
`ERROR: cannot insert a non-DEFAULT value into column "category_canonical"`
on the `INSERT INTO vendor_invoice_inbox`.

**Root cause:** `category_canonical` is `GENERATED ALWAYS AS
vendor_category_canonical(vendor_category) STORED` (added in V42).
Generated columns reject explicit values in INSERT/UPDATE.

**Fix:** dropped `category_canonical` from the column list in the
ingester's INSERT statement — Postgres derives it automatically from
`vendor_category`.

**Related:** see `feedback_pg_generated_cols_in_triggers.md` for the
*read* side of generated-column gotchas (NULL in BEFORE-trigger NEW).
The *write* side: don't put them in the column list at all.

---

## 2026-05-15 — psql `SET` command pollutes captured stdout under `-tA`

**Symptom:** `u78-ingest-utility.py`'s `lookup_mapping()` parsed `SET\n3`
as the first column of the result row → `ValueError: invalid literal for
int() with base 10: 'SET\n3'`.

**Root cause:** Even under `-tA` (tuples-only, unaligned), psql prints
the command tag `SET` to stdout when a `SET` statement runs. Same for
`BEGIN`/`COMMIT`. When the wrapper script prepends `SET LOCAL
app.current_entity = 'X'; SELECT …` and captures stdout, the `SET` line
appears before the SELECT result.

**Fix:** add `-q` (quiet mode) → `psql -tAq …` AND filter stray
`SET`/`BEGIN`/`COMMIT` lines defensively before parsing. Belt and braces.

**Bonus:** `SET LOCAL` outside an explicit transaction block emits
`WARNING: SET LOCAL can only be used in transaction blocks` and has no
effect — wrap in `BEGIN;…COMMIT;` if you actually need transactional
scope. (For postgres-superuser scripts this rarely matters since
superuser bypasses RLS anyway.)

---

## 2026-05-08 — n8n Postgres node drops RETURNING rows on multi-statement (BLOCKED)

**Symptom:** Master Router's `Claim Batch` node receives `{"success": true}`
instead of the claimed event rows. Switch v3 has no event_type to route on,
falls to fallback. Email Pipeline never gets called even though events ARE
being claimed (status pending → processing).

**Root cause:** n8n's Postgres v2.5 `executeQuery` operation appears to
treat any query that includes `set_config(...)` or `SET LOCAL` differently
— possibly using `pool.execute()` (returns rowCount only) instead of
`pool.query()` (returns rows). Tried three SQL shapes (multi-statement,
CTE-wrapped UPDATE-with-RETURNING, CTE+outer-SELECT) — same result. Direct
psql shows rows; n8n consumes the row count and discards the rows.

**Status:** OPEN. Three candidate fixes for next session, in preference
order:
1. Move logic into a SECURITY DEFINER Postgres function
   (`claim_event_batch()`); n8n calls `SELECT * FROM claim_event_batch();`
   as a single SELECT statement, no RLS bypass needed in the workflow.
2. Create a dedicated `homeai_router` role with BYPASSRLS, switch the n8n
   credential to use it. Eliminates need for SET LOCAL in the workflow.
3. Split into two Postgres nodes — first SELECT pending events, second
   UPDATE by id. Keeps RLS but doubles round-trips.

**Why this matters:** Item 1 of the 2026-05-08 sprint (synthetic email
test) is blocked on this. Real Gmail Ingest will hit the same wall once
emails start arriving. Resolving it is the precondition for Step 11.
