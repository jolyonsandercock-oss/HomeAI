# U231 — Postgres role least-privilege (closes U151b T4)

**Realm:** work (ops hardening; WORK-only per realm split).

**Trigger:** Per memory `feedback-service-pg-user-audit`: most services in the stack currently connect to Postgres as the `postgres` superuser. V177 introduced per-service roles (`paperless`, `n8n`, `metabase`, plus `homeai_readonly`) but they were created `NOLOGIN`. The U151 T4 migration to least-privilege was deferred to U151b — which shipped vision-OCR but not the role swap.

**Status:** queued.

**Why it matters:**
- A compromised n8n workflow, a SQL-injection in an HTTP service, or a bug in any one container currently has full superuser DDL on the entire database — drop tables, change privileges, read every realm's secrets.
- We have a 3-realm model (owner/work/personal) per `project-realm-split` and RLS policies per row, but RLS is bypassed when you connect as superuser. So the realm enforcement is *advisory* for most service connections today.
- Cost of migration is moderate; cost of waiting is the risk of any future incident bypassing all our isolation.

---

## T1 — Decide Path A vs Path B

Per memory `feedback-service-pg-user-audit`:
- **Path A** — Per-service `PG_DSN` swap: each service gets its own role + password, env vars supplied via Vault-Agent templates. Simpler. One role per container.
- **Path B** — Per-request `SET ROLE`: connect as a shared low-priv role, escalate within-transaction to the appropriate realm role for the duration of the call. More flexible (handles per-request realm switching) but requires app code changes.

**Recommended:** **A first** for all non-realm-multiplexed services (paperless, metabase, alertmanager, build-dashboard). **B later** for services that genuinely need per-request realm switching (mainly bot-responder + frontend). Capture the decision in `/home_ai/.claude/decisions/U231-pg-role-path.md`.

## T2 — Role + password setup (vault-side)

- [ ] Enable LOGIN on the V177 roles + set strong random passwords:
  ```sql
  ALTER ROLE paperless LOGIN PASSWORD :pw;
  ALTER ROLE n8n LOGIN PASSWORD :pw;
  ALTER ROLE metabase_app LOGIN PASSWORD :pw;
  ALTER ROLE homeai_readonly LOGIN PASSWORD :pw;
  -- add: alert_sink, build_dashboard, bot_responder, mcp_server, data_proxy
  ```
- [ ] Generate one strong password per role; write to vault under `secret/postgres-roles/<role>` (matches existing vault-agent template path).
- [ ] Add template entries to `/home_ai/services/homeai-vault-agent/agent.hcl` for each new role's password — one `/run/secrets/<role>-password` file per role.
- [ ] Reload vault-agent (or recreate the container).

## T3 — Per-service migration order

Migrate one service per session, least disruptive first. After each, run `selftest.sh` + 24h soak.

- [ ] **paperless** (already had its own password fall-out; clean migration target). Switch `PAPERLESS_DBUSER` to `paperless`, `PAPERLESS_DBPASS_FILE` to `/run/secrets/paperless-password`.
- [ ] **metabase** (already has its own role per V177).
- [ ] **alertmanager / alert-sink** — n8n needs the alert-sink workflow to connect with a role that has only INSERT on `system_alerts` + `audit_log`. Wire via a per-credential override in n8n.
- [ ] **build-dashboard** — read-mostly; use `homeai_readonly` + targeted INSERTs.
- [ ] **mcp-server** — use `homeai_readonly`.
- [ ] **bot-responder** — needs realm-switch ability → likely Path B per memory.
- [ ] **n8n** — keep superuser DSN for the workflow engine itself (it owns its DB schema), but force individual workflow nodes to use their own credentials via the n8n credentials store.

## T4 — Test RLS actually engages

The point of least-privilege is to make RLS bind. Verify:

- [ ] As `metabase_app`, can SELECT only WORK-realm tables (no personal data).
- [ ] As `paperless`, no SELECT on tables outside `paperless` namespace.
- [ ] As `homeai_readonly`, can SELECT but cannot INSERT/UPDATE anywhere.
- [ ] As any non-superuser role, DROP TABLE fails.
- [ ] As `bot_responder` (when Path B is wired), can `SET ROLE` only to the realm passed in the request context, not arbitrary ones.

## T5 — Watchdog: detect superuser drift

After migration, prevent regressions:

- [ ] New Prometheus alert `PostgresSuperuserConnection` — gauge from `pg_stat_activity` count where `usename='postgres'` and `application_name NOT IN (allowlist)`. Allow only known-superuser tools (e.g. `psql`, the migration runner).
- [ ] Routes through alert-sink → notify-bridge (U228 path).

## T6 — Document

- [ ] `/home_ai/docs/pg-roles.md`: role → service mapping table, password rotation procedure (revoke + new vault write + service restart), RLS expectations per realm.

---

## Deferred / out of scope

- **Per-row RLS policy review** — separate audit needed for whether existing policies cover the new role landscape. Filed as future U.
- **Migrating n8n workflow-engine connection itself** — n8n owns its schema (workflow_entity, execution_entity, etc.) and needs DDL → keep that DSN as superuser. Only workflow *node* credentials migrate.
- **Postgres password rotation cadence** — Vault Agent can do dynamic credentials (lease-based, rotated automatically). Worth a future U; for now static passwords held in Vault is the floor we should hit first.
- **Replication / read-replicas** — not part of this sprint.
