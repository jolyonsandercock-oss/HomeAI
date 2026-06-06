# Hardening — Reversible, Self-Testing Overnight Sprints

**Date:** 2026-06-06 · Planning only. Sequences the remaining hardening backlog
(from the #260 system review + this session) into **independently reversible,
self-verifying** sprints safe to run unattended overnight. Ordered safest→riskiest;
each sprint is gated by its own self-test and auto-rolls-back on failure.

---

## The pattern every sprint follows

```
snapshot  → apply change → self-test → PASS: keep + log + commit
                                     → FAIL: auto-rollback + alert + STOP the run
```

- **Snapshot/rollback unit** is explicit per sprint (a migration with a paired
  `DOWN`, a retained n8n `workflow_history` version, a backed-up image tag, a saved
  config). No change ships without a one-command revert.
- **Self-test** is a concrete assertion run *in the live system after the change*
  (a query, an HTTP probe, an RLS check), not "looks right." A sprint is only
  "done" when its test passes.
- **Guardrails** (reuse the U243 overnight harness): clear `system.state` first,
  honor the £3/day budget cap, abort the whole run if any sprint fails its test or
  if dead-letters/`CronStale` alerts climb. The new `cron-health-check.py` watchdog
  is the overnight safety net.
- **Runner:** `scripts/hardening-overnight-runner.sh` executes sprints in order,
  each as `precheck → apply → test → keep|rollback`, writing a per-sprint log and
  a final summary; stops at the first FAIL leaving the system in a known-good state.

---

## Sprint order (safest first — fail early, fail cheap)

### H1 — emails Full-Text Search (review A3) · risk: low
- **Change:** add a `tsvector` column + GIN index on `emails.body_text` (or a
  generated column), repoint the `email_search` slug to `plainto_tsquery`.
- **Reversible:** migration `Vxxx` + `DOWN` dropping the column/index; slug change
  is a single-row revert.
- **Self-test:** `EXPLAIN` the search query asserts a Bitmap Index Scan on the GIN
  index (not Seq Scan); a known term returns the expected row count vs the old ILIKE.
- **Effort:** ~1h.

### H2 — realm isolation on the gap tables (review A4) · risk: low-med
- **Change:** apply the established `entity_isolation`/`realm_isolation` policy
  pattern to `snag_inbox`, `vendor_category_rules`, `card_statements`,
  `email_priority_keywords` (tables currently without RLS).
- **Reversible:** `DROP POLICY` per table.
- **Self-test:** with `app.current_realm='personal'`, a `work`-realm row is NOT
  visible; with `='owner'`, all rows visible. Assert counts differ correctly. Also
  assert the services (still superuser pre-U249) are unaffected.
- **Effort:** ~2h.

### H3 — insert-time guards (review A6 + B4) · risk: low
- **A6 slug validation:** `validate_slug()` runs `EXPLAIN` on the template at
  `approved_at`; reject slugs that fail to plan (prevents the `full_name`/`team`
  class of runtime breakage).
- **B4 idempotency:** widen the invoice composite key to
  `(supplier, inv_no, source_file_hash)` so a corrected re-import isn't silently
  dropped.
- **Reversible:** both are additive functions/constraints with a `DROP`.
- **Self-test:** a deliberately-broken slug is rejected; a same-invoice re-import
  with a *different* file hash inserts (not skipped); identical re-import is skipped.
- **Effort:** ~2h.

### H4 — API write-auth (review A1) · risk: med (image rebuild)
- **Change:** (a) `breakfast/submit` — enforce token freshness (reject
  `service_date` older than 2 days; the HMAC is currently non-expiring). (b) Verify
  `dinner/remind` + `feedback/line` sit behind Authelia `/dashboard*` forward_auth
  (Caddyfile) — if confirmed, document as perimeter-protected; if not, add a
  Vault-HMAC `Bearer` check. Rebuild `build-dashboard` (baked image).
- **Reversible:** keep the previous `home_ai-build-dashboard` image tag; revert =
  retag + recreate. Caddyfile change is a backed-up file.
- **Self-test:** POST breakfast with a stale token → 400; with a fresh token → 200.
  Curl the admin endpoints unauthenticated → 401/redirect. `build-dashboard`
  `/healthz` green + a known dashboard query works post-rebuild.
- **Effort:** ~3h.

### H5 — RLS service-role migration (MASTER §2 / U147 / U151b) · risk: HIGH — last
- **Change:** move `bot-responder` + `build-dashboard` off the `postgres`
  superuser. **Path B (lower-risk) first:** keep the connection but `SET ROLE
  <realm_role>` per request/transaction, so RLS is enforced without touching the
  login. Only if Path B is clean, consider Path A (dedicated LOGIN role + Vault pw +
  env swap) later.
- **Reversible:** Path B is a code change behind a feature flag
  (`RLS_ENFORCE_SET_ROLE`); revert = flag off + restart. Per-table `GRANT`s are
  scripted with a paired `REVOKE`. No `ALTER ROLE ... LOGIN` in this sprint.
- **Self-test (must pass each before proceeding):**
  1. Pre-audit: enumerate every table each service reads/writes; assert the target
     role has matching `GRANT`s (fail = stop, the missing-grant outage class).
  2. After enabling SET ROLE on a **canary** path: the service completes a real
     read AND write (e.g. a dashboard query + an audit_log insert) successfully.
  3. Confirm RLS now actually filters (a cross-realm row is hidden) — proving the
     superuser bypass is gone.
  4. No new dead-letters / 5xx for 10 min.
- **Rollback:** flag off → service back to superuser connection instantly.
- **Effort:** ~1 full session. **Do NOT bundle with other sprints.** This is the
  one with real outage potential (`feedback_db_role_login_loss`,
  `feedback_service_pg_user_audit`); the staged self-tests are the safety.

### H6 — frontend headers + bundle (review A5 + A8) · risk: low, deferrable
- **A5:** CSP / X-Frame-Options / X-Content-Type-Options + a simple in-memory rate
  limiter (10 req/min/IP) on write routes. **A8:** `dynamic()` code-split the heavy
  pages (sales chart, tasks table, rooms). Frontend rebuild.
- **Reversible:** previous frontend image tag.
- **Self-test:** response headers present; rate limiter returns 429 on the 11th
  rapid request; pages still render (Playwright smoke).
- **Effort:** ~2h.

---

## Not in this series (decide separately)
- **U250 degraded integrations:** Trail (Playwright rewrite), Dojo (accept manual
  CSV), Xero Sync (API-blocked), **Qdrant keep-or-kill** (unused — reclaim resources
  or wire in). These are *decisions*, not reversible code sprints.
- **P9 report ingestion:** dormant by design; activating it is a design question
  (cost + harvest overlap), not a hardening sprint.

## Suggested cadence
One sprint per night, in order, each gated by its self-test. H1→H4 can run on
consecutive nights unattended via the runner. **H5 (RLS) should be attended** (or at
least run with someone reachable) despite the auto-rollback, given the blast radius.
H6 last / whenever.
