# H5 — RLS Service-Role Migration: Findings & Rollout Path

**Date:** 2026-06-06 · Path B canary executed (attended). Mechanism **proven**,
shipped behind `RLS_ENFORCE_SET_ROLE` (default **0** = pre-H5 superuser behaviour).

## What was done
- build-dashboard's shared DB helpers (`db_one`, `db_all`, `db_session`) now route
  through `_apply_db_context()`. When `RLS_ENFORCE_SET_ROLE=1` it does
  `SET LOCAL ROLE homeai_pipeline` (transaction-scoped — pooled connections never
  leak the de-privileged role) and sets **both** `app.current_entity` and
  `app.current_realm` before the query.
- Canary endpoint `/api/healthz-rls` proves the mechanism end-to-end through the
  live pool (realm-filtered read of `bank_transactions` + a savepoint-rolled-back
  `audit_log` write). Reachable under the `/api/healthz` middleware exemption.
- Flag wired into `docker-compose.yml` as `${RLS_ENFORCE_SET_ROLE:-0}`; toggle in
  `.env`, recreate to apply, set back to `0` to revert instantly.

## Canary results (all 4 plan self-tests passed)
| Flag | running_as | bypasses_rls | bank_txn owner/work/personal | write |
|------|-----------|--------------|------------------------------|-------|
| OFF  | postgres        | true  | 22476 / 22476 / 22476 (bypassed) | ok |
| ON   | homeai_pipeline | false | 22476 / 12941 / 9535 (filtered)  | ok |

No 5xx / errors during the flag-on window; `/api/healthz-deep` stayed 200.

## The landmine this surfaced (why full rollout is NOT yet flipped)
1. **`SET ROLE` does not inherit the role's `ALTER ROLE ... SET` defaults.**
   `homeai_pipeline` has defaults `app.current_entity=all, app.current_realm=owner`,
   but those apply only on a real LOGIN. Under `SET ROLE` they are absent.
2. **`entity_isolation` is PERMISSIVE and fails closed.** With `app.current_entity`
   unset, it denies every row — a *silent 0-row blackout*, not an error. The first
   canary (realm set, entity unset) returned 0 rows for every realm. Fix: the helper
   always sets `app.current_entity` (default `'all'`).
3. **`home_ai.set_realm()` sets only the realm, never the entity.** Any code that
   relies on it for RLS context must also set the entity under `SET ROLE`.

## ROLLOUT 2026-06-07 — flag ENABLED in production (helper paths)

- **Grant gap closed (V246):** `GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES`
  + `USAGE,SELECT ON ALL SEQUENCES IN SCHEMA public TO homeai_pipeline`, plus
  `ALTER DEFAULT PRIVILEGES` so future tables/sequences auto-grant. Re-audit: 0
  missing across all four privileges + sequences. (homeai_pipeline stays
  non-super/non-bypassrls, so RLS still enforces — table grants are coarse, RLS
  is the row boundary; this is the same config n8n already runs under.)
- **Soak-tested under flag ON:** 68/69 GET `/api/*` endpoints clean via the
  `X-Realm: all` test override; the one 500 (`/api/vehicles`) is a PRE-EXISTING
  malformed-query bug (`column "due" does not exist`, main.py ~4798), unrelated
  to RLS (the `vehicles` table reads fine as homeai_pipeline). healthz-deep 200,
  0 firing alerts. Canary: running_as=homeai_pipeline, bypasses_rls=false,
  bank_txn owner/work/personal = 22476/12941/9535 (filtered).
- **Default flipped to 1** in docker-compose.yml. Helper-path queries
  (db_one/db_all/db_session) now enforce RLS. Instant rollback: `.env`
  `RLS_ENFORCE_SET_ROLE=0` + recreate.

### Phase B — STARTED 2026-06-07; scope collapsed after investigation
- [x] **`/api/vehicles`** — fixed the pre-existing malformed query (v_vehicle_alerts
  → due_date/days_to_due) AND migrated off the inline pool to `db_session` — first
  inline→helper conversion; now enforces RLS. (commit 4695f27)
- [x] **bot-responder — already enforced, no migration needed.** Its
  security-critical path (`run_slug`, executing AI/slug SQL) runs on a dedicated
  **`homeai_readonly`** (non-superuser) connection in a `readonly=True` tx with
  `SET LOCAL app.current_entity` + `set_realm(caller_realm)` — RLS already applies
  (responder.py:157-173, ro_dsn at 299-303). The superuser `PG_DSN` connection is
  used ONLY for internal bookkeeping writes (query_rejections, audit, status). This
  is arguably a cleaner pattern than the dashboard's SET ROLE.
- [ ] **Inline-pool dashboard endpoints** (~50 sites, main.py) still acquire
  `pool()` directly + `SET app.current_entity` inline → stay superuser under the
  flag (unenforced, not broken). These are owner-facing admin/dashboard reads;
  RLS adds marginal value for single-owner usage. **Recommendation: migrate
  opportunistically when touching each endpoint** (as done for vehicles), not as a
  risky 50-edit big-bang. Heterogeneous (entity 'all'/'1', some hardcode
  set_realm('work'), a few session-level `set_config(...,false)`), so each needs
  its entity/realm preserved — `db_session` would need an optional realm override
  to migrate the hardcoded-realm ones uniformly.

## (historical) Before flipping `RLS_ENFORCE_SET_ROLE=1` in production
- [ ] **Grant-gap audit on writes.** `homeai_pipeline` has INSERT on 191/254 and
      UPDATE on 180/254 public tables. Helper-using write endpoints that target an
      ungranted table will `permission denied` (500) under the flag. Enumerate
      every table written via `db_session`/`db_one`/`db_all` and `GRANT` the gaps
      (scripted, with paired `REVOKE`).
- [ ] **Migrate inline-pool endpoints.** Many endpoints `await pool().acquire()`
      directly and `SET app.current_entity=...` inline instead of using the helpers
      (e.g. main.py ~2002–2335). Under the flag these stay superuser → inconsistent
      enforcement. Route them through the helpers (or add `SET LOCAL ROLE` there).
- [ ] Repeat for **bot-responder** (separate service, same superuser connection).
- [ ] Then enable the flag attended, watch dead-letters + 5xx for the soak window.

## Rollback
`RLS_ENFORCE_SET_ROLE=0` in `.env` + `docker compose up -d build-dashboard`.
Image rollback (unrelated regressions): `homeai-build-dashboard:pre-h5`.
