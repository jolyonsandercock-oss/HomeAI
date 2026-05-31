# U147 — Realm enforcement: make RLS partitioning real

**Realm**: cross-cutting (security). **Remote vs in-person**: 100% remote.
**Risk**: Phase A low; Phase B high (wrong role on a service breaks it).

> **Refreshed 2026-05-31** against live state. The original plan assumed
> migration `V177` still had to *create* the realm roles — that work is already
> done. The roles exist and `home_ai.set_realm` already enforces role↔realm
> pairing. What's actually missing is (1) a transaction-scoping bug that makes
> the frontend's realm setting evaporate, and (2) services still connecting on
> over-privileged roles. Plan re-scoped accordingly.

## Current state (verified 2026-05-31)

- **Roles already exist**: `owner_role` (NOLOGIN, **BYPASSRLS**, NOINHERIT),
  `personal_role` (NOLOGIN, NOINHERIT), `trading_role` (NOLOGIN, NOINHERIT),
  plus legacy `homeai_readonly`, `homeai_pipeline`, `homeai_hr`.
- **`home_ai.set_realm(text)` already enforces role↔realm pairing**
  (SECURITY DEFINER): `trading_role` may only set `work`; `personal_role` only
  `personal`; `owner_role`/superuser any realm; `homeai_readonly`/`pipeline`
  fall through unrestricted (can set any realm but can't *bypass* RLS).
- **`realm_isolation` RLS policy** is on **~96 tables** (not the "4/23" the old
  plan said). Its branches map owner→all, work→{work,shared},
  personal/family→{family,personal,shared}, and — critically —
  **`app.current_realm` NULL or '' → TRUE (sees everything)**. This transitional
  branch is the safety hole.
- **Service connection roles (live)**:
  | service | connects as | problem |
  |---|---|---|
  | homeai-frontend | `homeai_readonly` | not a realm role; relies on app passing realm — and that's currently broken (see Bug A) |
  | homeai-n8n | `homeai_pipeline` | legacy role, not realm-scoped |
  | homeai-bot-responder | **`postgres` superuser** | bypasses ALL RLS; DSN password in container env, not vault-rendered |

### Bug A — realm setting evaporates (root cause of "/invoices shows all realms")

`lib/db.ts` `runSlugDirect` (and `verifyPurchase`) call
`SELECT home_ai.set_realm($1)` then the slug query as **two separate
autocommit statements** on a pooled client. `set_realm` uses
`set_config('app.current_realm', realm, true)` — `is_local=true` = SET LOCAL =
**transaction-scoped**. With no surrounding transaction each statement is its
own implicit txn, so the realm is discarded before the slug query runs →
`app.current_realm` is NULL → policy returns all realms. The realm filter has
therefore never actually been in force on the frontend read path.

## Phase A — close the exposure (LOW risk, no role migration) — ✅ DONE 2026-05-31

Goal: make the *existing* RLS partitioning actually take effect on the frontend,
without touching connection roles.

**Outcome: the exposure was real and is now closed.** It turned out to have TWO
compounding causes, not one — the transaction bug *and* a view-layer RLS bypass
that the original plan didn't anticipate.

### A1 — Wrap set_realm + query in one transaction ✅
- **File**: `services/homeai-frontend/lib/db.ts`. Added a `withRealm()` helper
  (BEGIN → set_realm → fn → COMMIT, ROLLBACK on error). SET LOCAL now persists
  for the query and auto-clears on COMMIT (pool-safe). Applied to
  `runSlugDirect`, `verifyPurchase`, `upsertCashupInput`, `insertSafeMovement`
  (the writes shared the bug and would have broken under Phase B default-deny).
- Typecheck clean; rebuilt + force-recreated `homeai-frontend`.

### A1b — Views were bypassing RLS (NOT in the original plan) ✅
- Discovered the transaction fix alone didn't close the leak: the invoice views
  are owned by `postgres` (BYPASSRLS) and lacked `security_invoker`, so SELECTs
  through them evaluate RLS as the *view owner* → bypassed. The `:realm` SQL
  param was the only realm filter.
- **Migration `V216__u147a_view_security_invoker.sql`**: `security_invoker=true`
  on `v_purchase_search`, `v_cogs_period`, `v_gross_margin_period`. Now they
  honour RLS as the calling role (`homeai_readonly` + pinned realm).

### A2 — Verified on the running system ✅
- `purchase_kpis?realm=personal` → 0 / null (was £62k / 65 invoices);
  `?realm=work` → £92k / 487 intact. `purchase_search?realm=personal` → `[]`.
- All invoice/sales slugs http 200 (gross_margin_period, purchase_exceptions,
  spend_summary, spend_by_month, daily_cogs_7d_avg). Selftest 50/1 (the 1 FAIL
  is unrelated: nightly backup age).
- Proxy path (`runSlugViaProxy`, used when `HOMEAI_DATA_URL` set) is NOT active
  here (frontend connects direct) — but it does NOT set realm and would leak if
  ever enabled. **Carry into Phase B / proxy-service work.**

### A3 — /invoices realm toggle — now safe, gating deferred
- The leak is closed at the DB layer regardless of the toggle: every request
  uses request-realm `work` (the API route doesn't pass a realm), so RLS caps to
  work+shared and toggling to personal/owner returns empty. Hiding the toggle is
  now cosmetic, not a security need — deferred.

### Phase A follow-ups (carry into Phase B)
- **Full view-layer `security_invoker` audit**: every other postgres-owned view
  over a realm-aware table has the same BYPASSRLS property — e.g.
  `v_invoice_lines_resolved` (vendor_invoice_* tables), `v_daily_gp`. Sweep them.
- `daily_gp_recent` slug is registered `realm=owner` → the sales-page GP-recent
  panel 400s on a work request (pre-existing, separate from this work).
- The RLS `NULL/'' -> TRUE` escape hatch still means any unwrapped query leaks —
  becomes default-deny in B5.

## Phase B — role-layer defence (HIGH risk — PAUSE FOR JO'S GO)

Goal: defence-in-depth so a forgotten `set_realm` can't leak data, by binding
each service to a realm role and removing the NULL→TRUE escape hatch.

### B1 — Sandbox pen-test (~2h)
- Restore latest backup to a sandbox PG on port 5433 (do NOT pen-test live).
- Script `scripts/u147-rls-pentest.sh`, looping the **current** realm-aware
  tables (generate the list programmatically — see the ~96-table query in this
  doc's history; key ones: `purchases`, `purchase_lines`, `bank_transactions`,
  `mortgage_*`, `card_statements`, `medical_history`, `children`, `emails`):
  ```sql
  SET ROLE trading_role;  SELECT home_ai.set_realm('work');
  SELECT count(*) FROM purchases WHERE realm IN ('personal','family');  -- expect 0
  SET ROLE personal_role; SELECT home_ai.set_realm('personal');
  SELECT count(*) FROM purchases WHERE realm='work';                    -- expect 0
  ```
- Also verify `set_realm` refuses cross-pairing (trading_role setting
  'personal' must RAISE 42501).
- **Acceptance**: all-green log to `audits/u147-rls-pentest-<date>.log`.

### B2 — Consumer mapping (~30 min)
- Enumerate every postgres consumer and assign a role. Draft:
  | service | new role | rationale |
  |---|---|---|
  | homeai-frontend | `trading_role` | work-only reads; role caps realm at work |
  | build-dashboard | `trading_role` | work-only |
  | homeai-bot-responder | `owner_role` | needs cross-realm; **off superuser** |
  | homeai-n8n (pipelines) | `owner_role` | writes events across realms |
  | homeai-google-fetch | `owner_role` | writes multiple realms |
  | metabase | `homeai_readonly` (or trading_role) | dashboards — decide |
- `trading_role`/`personal_role` need LOGIN + a vault-stored password +
  `GRANT`s mirroring what `homeai_readonly`/`homeai_pipeline` have today.
- Save as `.claude/plans/u147-consumer-mapping.md`.

### B3 — Grant + give realm roles LOGIN (migration `V216__u147_realm_roles_login.sql`)
- `ALTER ROLE trading_role LOGIN PASSWORD <vault>;` (+ personal_role).
- Mirror table GRANTs from the legacy roles onto the realm roles.
- Store passwords in vault (`secret/postgres-roles`); **never in compose/env**.
- Rollback = `ALTER ROLE … NOLOGIN`.

### B4 — Migrate connection strings one service at a time (~2h)
- Move secrets to vault-agent-rendered files; point each service's DSN at its
  assigned role. **bot-responder first** — get it off the `postgres` superuser.
- After each: restart, smoke-test, watch `security_audit_log` for refused
  realm-bypass attempts.
- After rotating `secret/postgres-roles`, run
  `sync-n8n-postgres-credential.sh` (AGENTS.md rule 12).

### B5 — Remove the NULL→TRUE escape hatch (migration `V217__u147_realm_default_deny.sql`)
- Replace the policy's `WHEN app.current_realm IS NULL/'' THEN true` with
  `THEN false` (default-deny) **only after** B4 confirms every service sets a
  realm. This is the irreversible-feeling step — do it last, with a tested
  rollback migration ready.

### B6 — Soak + drop legacy roles (~1 day later, migration `V218`)
- 24h after B4, confirm zero connections under `homeai_readonly` /
  `homeai_pipeline` (`pg_stat_activity`), then `DROP ROLE` them.

## Done criteria
- Phase A: frontend reads are realm-filtered; `/invoices` work-only; selftest green.
- Phase B: pen-test green across realm-aware tables; every service on its
  assigned role; bot-responder off superuser; NULL→TRUE branch removed; legacy
  roles dropped; selftest stays green.

## Notes / decisions for Jo
- **Phase A is a quick safe win** that closes the live personal-data exposure on
  `/invoices` without the role-migration blast radius — worth pulling forward
  independently of Phase B.
- `owner_role` has BYPASSRLS, so owner-realm services are unguarded by design;
  the partitioning defence really protects `trading_role`/`personal_role`
  services. Acceptable, but document it.
- The bot-responder superuser DSN with an inline password is an adjacent
  hardening item (vault-render it) — fold into B4.
