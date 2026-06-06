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

## Before flipping `RLS_ENFORCE_SET_ROLE=1` in production
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
