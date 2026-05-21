# U151 — Pipeline robustness + hardening sign-off close

**Prereqs**: U146/U147/U148 shipped (Report Ingestion patched, V177 live + pen-tested, quota shadow-audit complete).

**Realm**: cross-cutting.

**Remote vs in-person**: 100% remote. Three Jo sign-offs gate this sprint:
1. Service migration green-light (per `.claude/plans/u147-consumer-mapping.md`)
2. Quota hard-mode flip green-light (per `.claude/audits/u148-shadow-7d.md`)
3. Lower DL threshold 20→5 green-light (after pipeline patches)

**Why this sprint exists**: U146-U148 closed the immediate stability + security audit but left three things gated on Jo's sign-off. Plus the Invoice + Nanny pipeline noOp-skip pattern is deferred. This sprint closes them all so Phase 6 has clean ground to build on.

## Tracks

### T1 — Invoice Pipeline robustness (~45 min)

**Realm**: cross-cutting.

**Build**:
- Inspect Invoice Pipeline (P2) for "0 rows returned" paths — specifically `Find Attachment` returning no rows when downstream query misses.
- Wrap the query in a CTE that always returns one row (mirror Report Ingestion's V2 idempotency pattern).
- Add a `Respond to Webhook` node OR a "Complete Event" postgres node at the empty-attachment terminus, so master-router gets a webhook payload instead of "No item to return was found".

**Acceptance**: trigger a known-incomplete invoice event; confirm webhook returns 200 with payload; events.status transitions to 'processed' within 5s.

### T2 — Nanny Pipeline robustness (~30 min)

**Realm**: cross-cutting.

**Build**: same pattern as T1 applied to Nanny Pipeline (P8). Likely target: `Fetch Children` returning 0 rows for events that don't match a child.

**Acceptance**: trigger an unmatched child.event.detected; confirm clean completion.

### T3 — Lower DL threshold 20 → 5 (~5 min)

**Build**: after 24h of T1+T2 in production, revert `system.limits.dead_letter_digest_threshold` to default 5.

**Pre-flight**: zero new DLs from Invoice + Nanny in last 24h.

### T4 — Service connection-string migration (~2 hours, **Jo's sign-off required**)

**Build**: per `.claude/plans/u147-consumer-mapping.md`:

For each service in the mapping table:
1. Update `docker-compose.yml` env var `PG_USER` (or equivalent) to new role.
2. `docker compose up -d <service>` to restart.
3. Verify health endpoint + one representative API call.
4. Watch `audit_log` for any `connection refused` / `permission denied` errors.
5. 1-hour soak before moving to next service.

**Order** (lowest blast radius first):
1. `paperless` (read-mostly) → `trading_role`
2. `metabase` → `owner_role`
3. `build-dashboard` → `trading_role`
4. `homeai-frontend` → `trading_role`
5. `bot-responder` → `owner_role`
6. `llm-router` → `owner_role`
7. `homeai-litellm` → `owner_role`
8. `critical-listener` → `owner_role`
9. `homeai-data-proxy` → `owner_role`
10. `homeai-n8n` → `owner_role` (highest blast — last)
11. `google-fetch` → `owner_role`

### T5 — Drop legacy roles (~15 min, after T4 + 24h soak)

**Build**: new `V179__u151_drop_legacy_roles.sql` — `DROP ROLE homeai_readonly, homeai_pipeline`. Only after `pg_stat_activity` confirms zero connections under those roles for 24h.

### T6 — Quota hard-mode flip (~10 min, **Jo's sign-off required**)

**Build**:
```sql
UPDATE quota_allocations SET enforce_mode = true;
```

Watch 24h for any unexpected blocks. Verify P0 floor alert via synthetic Prometheus test.

## Done criteria

- T1+T2: Invoice + Nanny pipelines process events to 'processed' status within 5s of completion (no 10-min recovery delay).
- T3: DL threshold back to 5; selftest stays green.
- T4: every service migrated to new role; pg_stat_activity shows zero connections under legacy roles.
- T5: legacy roles dropped; V179 in git.
- T6: enforce_mode = true; 24h of operation with 0 false blocks.

## Risk

Medium. T1/T2 follow proven Report Ingestion pattern (low risk). T4 is the highest-risk move — wrong role = service breaks. Mitigations: per-service soak; rollback = restore old role grant + restart.

## Outcome trigger for U152

Once U151 lands cleanly, U152 (staff-page UI) starts. Until U151 stabilizes, building on top would just amplify pipeline pain when staff start poking at it.
