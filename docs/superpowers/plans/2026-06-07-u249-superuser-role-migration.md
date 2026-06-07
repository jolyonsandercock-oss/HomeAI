# U249 — Superuser → Scoped-Role Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (phased, flag-gated rollout with checkpoints — NOT parallel subagents; ordering is load-bearing). Steps use checkbox (`- [ ]`) syntax.

**Goal:** Stop application services connecting as the `postgres` superuser (which BYPASSES RLS), so realm + entity isolation is actually enforced — then flip the systemic permissive-null realm policies to default-deny.

**Architecture:** Reuse the **proven Path B canary** already shipped in `build-dashboard`: the service connects as `postgres` but each transaction does `SET LOCAL ROLE homeai_pipeline` + sets **both** `app.current_entity` and `app.current_realm` GUCs, so RLS fires. This is rolled out service-by-service behind the existing `RLS_ENFORCE_SET_ROLE` flag (default OFF = byte-for-byte current behaviour, instantly reversible). Only *after* every consumer sets realm/entity do we (a) move DSNs off the superuser and (b) flip the permissive-null policies to deny.

**Tech Stack:** PostgreSQL roles + RLS, HashiCorp Vault (`secret/postgres-roles`), asyncpg/psycopg services, n8n Postgres credential, Docker Compose.

**Why phased & flag-gated:** Flipping default-deny or swapping a DSN before a consumer sets realm returns **0 rows silently** (entity_isolation is PERMISSIVE; `SET ROLE` drops GUC defaults — see `build-dashboard/main.py:117`). Each phase is independently shippable and reversible.

---

## Current state (verified 2026-06-07)

**Connect as `postgres` superuser (the F1 targets):**
| Service | compose line | role today |
|---|---|---|
| build-dashboard | 305 | postgres (**canary-ready**: `RLS_ENFORCE_SET_ROLE` implemented) |
| google-fetch | 407 | postgres |
| playwright | 541 | postgres |
| wa-bridge | 603 | postgres |
| bot-responder | 629 | postgres |
| critical-listener | 650 | postgres |
| postgres-exporter | 60 | postgres (**special** — needs monitoring grants, not a realm role) |
| n8n | (credential in n8n DB) | postgres (**biggest writer**) |

**Already scoped (readers, leave as-is):** data-proxy (573), frontend (589), mcp (615) → `homeai_readonly`. metabase → `metabase_app`; paperless → its own role.

**Roles:** `homeai_pipeline` (LOGIN, V246 grants ALL on public — broad), `homeai_readonly` (LOGIN, read + narrow sandbox writes V134). `trading_role/personal_role/owner_role` (V177, NOINHERIT) exist but the canary uses `homeai_pipeline` + realm GUC, not these — treat V177 roles as legacy; do **not** introduce them here.

**Proven pattern:** `services/build-dashboard/main.py:128` `_apply_db_context()`. **Harness:** `scripts/u52-realm-shadow-test.sh`. **Smoke:** `scripts/u71-pipeline-role-smoke.sh`. **Creds:** Vault `secret/postgres-roles` (fields via `scripts/list-roles-keys.sh`); reset via `scripts/fix-*-role-pw.sh`.

---

## Phase 0: Grant-gap audit (gates everything else)

**Why:** Phase 1 can use `homeai_pipeline` immediately (V246 = ALL grants, so no gaps), but Phases 3–4 (DSN swap + grant-narrowing) need to know exactly what each service touches.

- [ ] **0.1** For each superuser service, list the tables/functions/sequences it touches:
  ```bash
  for s in build-dashboard google-fetch playwright wa-bridge bot-responder critical-listener; do
    echo "== $s =="
    grep -rhoiE "(from|join|into|update|delete from)\s+[a-z_][a-z0-9_.]*" services/$s/ \
      | awk '{print tolower($2)}' | sort -u
    grep -rhoiE "home_ai\.[a-z_]+\(" services/$s/ | sort -u
  done
  ```
- [ ] **0.2** Record the union per service into `docs/u249-grant-matrix.md` (service → {tables: r/w, functions: execute}). This is the spec for Phase 4 grants.
- [ ] **0.3** Confirm `homeai_pipeline` can already reach all of them (it has ALL via V246): `psql ... -c "\du homeai_pipeline"` and spot-check with the smoke script. Commit the matrix.

---

## Phase 1: Enforce RLS on the Python writer services (flag-gated, reversible)

Roll the proven `_apply_db_context` pattern to each service, then enable `RLS_ENFORCE_SET_ROLE=1`. The DSN stays `postgres` in this phase — enforcement comes from `SET LOCAL ROLE`. **One service per task**, shadow-tested before the next.

**Shared code to port (from `build-dashboard/main.py:108-145`) into each service's db helper:**
```python
RLS_ENFORCE_SET_ROLE = os.environ.get("RLS_ENFORCE_SET_ROLE", "0") == "1"
RLS_SET_ROLE_NAME = os.environ.get("RLS_SET_ROLE_NAME", "homeai_pipeline")
# (validate RLS_SET_ROLE_NAME against ^[A-Za-z_][A-Za-z0-9_]*$ — no interpolation of untrusted input)

async def _apply_db_context(conn, entity="all", realm="all"):
    # MUST be inside an open transaction.
    if RLS_ENFORCE_SET_ROLE:
        await conn.execute(f"SET LOCAL ROLE {RLS_SET_ROLE_NAME}")
    # ALWAYS set both GUCs: SET ROLE drops ALTER ROLE defaults and
    # entity_isolation is PERMISSIVE → missing entity = silent 0 rows.
    await conn.execute("SELECT set_config('app.current_entity', $1, true)", str(entity))
    await conn.execute("SELECT home_ai.set_realm($1)", realm)
```

### Task 1.1: google-fetch (template for 1.2–1.5)
**Files:** `services/google-fetch/main.py`, `docker-compose.yml:402-415`
- [ ] **Step 1: Baseline** — `scripts/u52-realm-shadow-test.sh --baseline` (captures current row counts).
- [ ] **Step 2:** Add the `_apply_db_context` helper; wrap every `conn.execute/fetch` write path so each runs inside a transaction that calls it first. The service already does `SET LOCAL app.current_entity='all'` in places (`main.py:85` etc.) — replace those with `_apply_db_context` so realm is set too.
- [ ] **Step 3:** Add `RLS_ENFORCE_SET_ROLE: "0"` to the service's compose env (so it's explicit and flippable). Rebuild: `docker compose build google-fetch`.
- [ ] **Step 4: Transitional check** — deploy with flag still `0`, run `u52 --check transitional` → expect **no drift** (byte-for-byte).
- [ ] **Step 5: Enable** — set `RLS_ENFORCE_SET_ROLE: "1"`, `docker compose up -d google-fetch`. Watch logs + the dashboard's `rls_enforce_set_role` health field for 0-row regressions for one full ingest cycle.
- [ ] **Step 6: Verify** — `u52 --check enforced` green; the service's reads/writes still return expected rows. If anything returns 0 rows → flag back to `0` (instant rollback), fix the missing GUC, retry.
- [ ] **Step 7: Commit** `git commit -m "feat(google-fetch): RLS_ENFORCE_SET_ROLE path-B enforcement (U249)"`

### Task 1.2 playwright · 1.3 wa-bridge · 1.4 bot-responder · 1.5 critical-listener
- [ ] Repeat Task 1.1 steps verbatim for each, one at a time. wa-bridge + bot-responder are writers to entity-1 (pub) data — default entity `'1'` where the write is pub-specific, `'all'` for cross-entity reads. critical-listener writes `system_alerts`/audit (non-RLS) — still set both GUCs for consistency.

### Task 1.6: build-dashboard — flip the canary on
- [ ] It already implements the pattern. Set `RLS_ENFORCE_SET_ROLE: "1"` in compose, `up -d`, run the full `u52 --check enforced`, watch the dashboard for empty widgets (a 0-row regression shows there). Roll back via flag if needed. Commit.

---

## Phase 2: Enforce RLS in the n8n pipelines (the biggest writer)

**Why separate:** n8n shares one Postgres credential across all nodes; many write nodes already `SET LOCAL app.current_entity` but **not realm**, and the credential is `postgres` (bypass).

- [ ] **2.1** Audit every n8n write node for both GUCs: `python3 scripts/audit-invariants.py | grep -E "INV-ENTITY"`. Each write node's query must begin with `SET LOCAL app.current_entity='…'; SELECT home_ai.set_realm('…');` (use the correct realm/entity for that pipeline; default entity `'all'` for the router/maintenance jobs).
- [ ] **2.2** Patch the offending nodes via the n8n API (new `workflow_history` row + repoint `activeVersionId` — editing the export file alone is a no-op). Mirror into `.claude/n8n-exports/`.
- [ ] **2.3** Create a `homeai_pipeline` **LOGIN** credential in n8n (password from Vault `secret/postgres-roles`). Point the "HomeAI Postgres" credential at it. Because the connection is now non-super, RLS fires on every node — so 2.1/2.2 must be complete first.
- [ ] **2.4** Run one event end-to-end through the master-router + each pipeline; confirm rows land and no node returns empty/00. Roll back = repoint credential to postgres.
- [ ] **2.5** Commit the workflow exports + a note in `docs/u249-grant-matrix.md`.

---

## Phase 3: Move DSNs off the superuser (the actual F1 fix)

Now every query sets realm/entity, so a non-super DSN is safe. Swap each writer to `homeai_pipeline`; this makes the `SET LOCAL ROLE` belt-and-suspenders (keep it — defence in depth).

- [ ] **3.1** Ensure `homeai_pipeline` LOGIN + password in Vault: `scripts/list-roles-keys.sh` shows the field; if missing, set it and store (pattern: `scripts/fix-paperless-role-pw.sh`). Smoke: `scripts/u71-pipeline-role-smoke.sh`.
- [ ] **3.2** Swap each writer DSN `postgresql://postgres:…` → `postgresql://homeai_pipeline:${HOMEAI_PIPELINE_PASSWORD}@homeai-postgres:5432/homeai` (compose lines 305, 407, 541, 603, 629, 650). Add `HOMEAI_PIPELINE_PASSWORD` injection from Vault (mirror how `HOMEAI_READONLY_PASSWORD` is wired).
- [ ] **3.3** postgres-exporter (line 60): create a dedicated `homeai_monitor` role (`GRANT pg_monitor TO homeai_monitor;`), swap its DSN — do **not** use homeai_pipeline (it needs `pg_stat_*`, not table grants).
- [ ] **3.4** `up -d` each service; verify health + `u52 --check enforced`. Roll back per service = revert its DSN line.
- [ ] **3.5** Verify the gate: `python3 scripts/audit-invariants.py | grep INV-PG-SUPERUSER` → only the intentional ones (if any) remain. Commit.

---

## Phase 4: Narrow grants + rename the misnamed role

- [ ] **4.1** New migration `V250__narrow_pipeline_grants.sql`: replace V246's `GRANT … ON ALL TABLES … TO homeai_pipeline` with per-table grants from the Phase 0 matrix (or move broad writes behind `SECURITY DEFINER` functions with narrow `EXECUTE`). Apply; re-run `u71` smoke + `u52 --check enforced`.
- [ ] **4.2** New migration `V251__rename_readonly_role.sql`: `ALTER ROLE homeai_readonly RENAME TO homeai_frontend;` (it has narrow sandbox writes — the name lied). Update DSNs (compose 573, 589, 615), `lib/db.ts:17`, Vault `secret/postgres-roles`. (Frontend plan Task 5 — fold it here.)
- [ ] **4.3** `up -d` affected services, verify, commit.

---

## Phase 5: Flip the systemic permissive-null realm policies to default-deny

**Why last:** only safe once every consumer sets realm (Phases 1–3 done). Before that, default-deny = silent 0 rows.

- [ ] **5.1** Enumerate the policies still carrying `WHEN app.current_realm IS NULL THEN true`: the ~14 migrations besides snag_inbox (V65, V65b, V68, V73, V96, V168, V174, V206, V218, V219, V225, V227, V228, V237→already fixed by V249). Confirm against **live** policies (not migration history — superseded ones like V237 don't count): `SELECT schemaname, tablename, policyname, qual FROM pg_policies WHERE qual LIKE '%current_realm%IS NULL%';`
- [ ] **5.2** `scripts/u52-realm-shadow-test.sh --check enforced` must be green for owner/work/personal across all affected tables **first** — proves every path sets realm.
- [ ] **5.3** New migration `V252__realm_policies_default_deny.sql`: for each live permissive policy, `DROP`/`CREATE` with the `ELSE false` form (the V249 shape). Apply inside one transaction.
- [ ] **5.4** Re-run `u52 --check enforced` + a full dashboard/pipeline smoke. Any table that now returns 0 rows for a legit realm = a consumer that still doesn't set realm → fix it, don't loosen the policy. Roll back = re-apply the prior policy bodies.
- [ ] **5.5** Commit.

---

## Phase 6: Lock the gate & document

- [ ] **6.1** Update `scripts/audit-invariants.py`: INV-PG-SUPERUSER should now expect zero superuser DSNs (any remaining must be explicitly allow-listed with a reason). Add a check that flags a `CREATE POLICY` with a permissive-null branch in **new** migrations (FAIL).
- [ ] **6.2** Flip the defaults: `RLS_ENFORCE_SET_ROLE` default → `1` in code (so a new deploy is secure-by-default), keep the env override for emergency rollback.
- [ ] **6.3** Update AGENTS.md build state + `decisions/` with the U249 completion record. Update the [[project-invariant-checker]] memory.
- [ ] **6.4** Final: `python3 scripts/audit-invariants.py` → no INV-PG-SUPERUSER / INV-ENTITY-GUC FAILs.

---

## Self-review

- **Coverage:** F1 superuser DSNs (Phases 1–3), F2 service entity GUC (Phase 1–2), broad `homeai_pipeline` grants / V246 (Phase 4.1), `homeai_readonly` misnomer / V134 (Phase 4.2), systemic permissive-null RLS / ~14 policies (Phase 5), n8n credential (Phase 2), monitoring special-case (3.3).
- **Reversibility:** every enforcement step is `RLS_ENFORCE_SET_ROLE` flag-off or a single DSN/credential revert; every migration has a documented inverse.
- **Ordering invariant:** consumers set realm/entity (1,2) → DSNs de-privileged (3) → grants narrowed (4) → policies default-deny (5). Never flip 5 before 1–3 or it returns 0 rows.
- **Key trap baked in:** always set BOTH GUCs after `SET LOCAL ROLE` (entity_isolation is PERMISSIVE; SET ROLE drops ALTER ROLE defaults) — `build-dashboard/main.py:117`.
- **Dependency:** assumes `homeai_pipeline` LOGIN + Vault password (3.1). If the SCRAM hash was lost in the U242 churn ([[feedback_db_role_login_loss]]), reset+store before Phase 3.
