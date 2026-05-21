# U147 — V177 role split: pen-test + live rollout

**Prereqs**: U146 shipped (system stable). V177 migration file exists, marked DRAFT.

**Realm**: cross-cutting (security).

**Remote vs in-person**: 100% remote.

**Why this sprint exists**: V177 is the highest-blast-radius migration in the stack. Adds three Postgres roles mapped to the realm model so connection-pool partitioning becomes a real defence layer rather than an app-layer GUC convention. Cannot ship without pen-test; cannot pen-test without sandbox.

## Tracks

### T1 — Sandbox DB pen-test (~2 hours)

**Build**:
- Restore latest restic backup to sandbox postgres: `restic restore latest --target /tmp/sandbox-pg`.
- Start sandbox container on alt port (5433): `docker run --rm --name homeai-postgres-sandbox -p 5433:5432 -v /tmp/sandbox-pg:/var/lib/postgresql/data postgres:16.13`.
- Apply V177 to sandbox.
- Pen-test script `scripts/u147-rls-pentest.sh`:
  ```sql
  SET ROLE trading_role;       SET app.current_realm='work';
  SELECT COUNT(*) FROM vendor_invoice_inbox WHERE realm='personal';  -- expect 0
  SET ROLE personal_role;      SET app.current_realm='personal';
  SELECT COUNT(*) FROM vendor_invoice_inbox WHERE realm='work';      -- expect 0
  SET ROLE owner_role;         SET app.current_realm='owner';
  SELECT COUNT(*) FROM vendor_invoice_inbox;                         -- expect total
  ```
- Repeat for the other 23 realm-aware tables. All must return 0 cross-realm rows under non-owner roles.

**Acceptance**: pen-test all-green, log written to `audits/u147-rls-pentest-<date>.log`.

### T2 — Consumer mapping table (~30 min)

**Build**: enumerate every service that connects to postgres + write the realm → role assignment.

```
service             | role            | rationale
--------------------|-----------------|-------------------------
build-dashboard     | trading_role    | work realm only
homeai-frontend     | trading_role    | work realm only
bot-responder       | owner_role      | needs cross-realm read
critical-listener   | owner_role      | system-wide audit writes
llm-router          | owner_role      | logs ai_usage across realms
n8n (pipelines)     | owner_role      | needs write to events table
google-fetch        | owner_role      | writes to multiple realms
... (full list)
```

Save as `.claude/plans/u147-consumer-mapping.md`.

### T3 — Apply V177 to live (~15 min — **PAUSE FOR JO'S GO**)

**Pre-flight checks** (all must pass):
- T1 pen-test green.
- T2 consumer mapping reviewed.
- Backup ran in last 6h.

**Build**: `psql -f postgres/migrations/V177__u145_rls_role_split.sql`.

**Rollback**: restore latest backup (V177 only ADDs roles; no data change; rollback is `DROP ROLE`).

### T4 — Migrate service connection strings (~2 hours)

**Build**: for each service in the mapping table, update `docker-compose.yml` env var `PG_USER` (or equivalent) to the new role. Restart services one-by-one; verify each still functions.

**Acceptance**: every service confirmed healthy with new role. No app-level realm-bypass attempts in audit log.

### T5 — Soak + drop legacy roles (~1 day later)

**Build**: 24h after T4, confirm zero connections under `homeai_readonly` / `homeai_pipeline`. Drop those roles. New migration `V179__u147_drop_legacy_roles.sql`.

## Done criteria

- All 4 realm-aware tables pass pen-test under each role.
- Every service in consumer mapping is on its assigned role.
- Legacy roles dropped without errors.
- Selftest stays green.

## Risk

**High** — wrong role on a service breaks it. Mitigations: sandbox pen-test mandatory; consumer mapping reviewed; one service migrated at a time; rollback = re-grant old role.
