# U52 — Realm R2 (RLS Enforcement)

**Prereqs**: R1 shipped (V64 / V64a — `realm` column on 92 home_ai domain tables, populated; `v_realm_audit` view; 950 work / 826 owner / 376 family across emails+events+vendor_invoice_inbox).

**Realm**: cross-cutting. Every track below carries its own `**Realm:**` line. The sprint *itself* is the realm enforcement layer — it touches OWNER (RLS catalog), WORK, FAMILY, and SHARED tables.

**Remote vs in-person**: 100% remote. No host sudo, no physical access, no Jo input. Suitable for unattended ~4h run.

**Why this sprint exists**: R1 labelled the data; nothing yet enforces realm at query time. Right now `app.current_entity` is the only RLS filter — adequate while Jo is the only login, dangerously inadequate the moment a WORK-realm pub-manager login (or FAMILY-realm member login) hits the system. Per [[realm-split-architecture]] R2 is the next step and must precede R3 (Auth) because the auth layer needs a database that already refuses cross-realm reads — defence-in-depth means the DB never trusts the app. R3 itself remains blocked on the tailscale-cert FQDN ([[feedback_authelia_cookie_domain]]), so R2 is also the only realm step we can land remote-only. R4 partial (the request-side GUC plumbing) folds into T5 here so the app is ready for R3 to drop in.

**Discipline carry-overs** (relevant to this sprint specifically):
- Rule #1 — verify before done. Every track ends with an SQL/curl gate that proves the policy is doing what the comment says.
- Rule #9 — break iteration loop after 3 attempts. RLS misconfigurations cascade silently (queries return empty, dashboards go blank). If T2 needs a 4th rewrite of the policy expression, **abort, restore, document, hand off to fresh session.**
- Rule #10 — audit consumers before replacing a producer. T2 changes the policy expression on `entity_isolation`. Every service that sets `app.current_entity` (build-dashboard, bot-responder, metabase_app, homeai_pipeline, readonly) must keep working. The `'all'` sentinel that homeai_pipeline relies on stays valid; OWNER realm = same effective scope as `'all'` for entity.
- Rule #6 (state sync) — already done at session start; 43 RLS-policied tables, 49 more carrying realm but no policy yet.

## Tracks

### T1 — Shadow validation harness (~45 min)

**Realm**: owner (test infrastructure lives in OWNER realm).

**Why this comes first**: every other track in this sprint mutates RLS policy expressions. Without a parallel-read regression battery to run *before* and *after* each migration, we cannot prove "OWNER still sees everything" / "WORK only sees entity 1" / "FAMILY only sees entities 2,3,4" with confidence. Cheaper than debugging blank dashboards.

**Build**:
- `/home_ai/scripts/u52-realm-shadow-test.sh`:
  - Connects as `homeai_pipeline` (the role used by services).
  - For each of `('owner', 'work', 'family')` × a fixed query battery (~20 queries hitting emails, events, vendor_invoice_inbox, workforce_shifts, bank_transactions, child_events, rent_payments, properties, caterbook_room_nights):
    - `SET LOCAL app.current_realm = '<realm>'; SET LOCAL app.current_entity = 'all';`
    - Capture row count + first row id-hash.
  - Writes a baseline JSON to `/home_ai/data/realm-shadow-baseline.json` on first run.
  - On subsequent runs: diffs against baseline, exits non-zero on any unexpected drift.
- `--baseline` flag overwrites baseline (call before T2 to capture **pre-policy** counts), then `--check` re-runs after each migration.
- Expected post-T2 shape: OWNER counts ≥ WORK + FAMILY counts on every table; WORK count + FAMILY count = total realm-bearing rows; both filters must drop OWNER-only rows for non-OWNER readers.

**Acceptance**:
- `bash u52-realm-shadow-test.sh --baseline` writes the JSON.
- `bash u52-realm-shadow-test.sh --check` returns exit 0 with no drift versus baseline (R1 state — no enforcement yet, so all three realm roles see same rows; this proves the harness runs cleanly before we start changing things).

---

### T2 — V65 migration: `app.current_realm` GUC + layered policy (~60 min)

**Realm**: owner. Migrations themselves are OWNER-only operations; the resulting policy applies to every realm.

**Build**:
- `postgres/migrations/V65__realm_rls_enforcement.sql`:
  - Adds a `realm_isolation` policy expression to every table that already has `entity_isolation`. **Does not replace** the existing policy — adds a second `USING` clause via a `CREATE POLICY realm_isolation … USING (…)`. RLS combines policies with **OR** by default, which is the opposite of what we want, so we use **FOR ALL** with `RESTRICTIVE` to ensure AND-composition with `entity_isolation`:
    ```sql
    CREATE POLICY realm_isolation ON <t> AS RESTRICTIVE FOR ALL
    USING (
      CASE
        WHEN current_setting('app.current_realm', true) = 'owner' THEN TRUE
        WHEN current_setting('app.current_realm', true) IN ('work','family')
             THEN realm = current_setting('app.current_realm', true)
                  OR realm = 'shared'
        WHEN current_setting('app.current_realm', true) IS NULL
          OR current_setting('app.current_realm', true) = ''
             THEN TRUE  -- transitional: unset realm = trust entity_isolation alone (R2 rollout)
        ELSE FALSE
      END
    );
    ```
    The `CASE` shape matches the existing entity policy idiom from V5 (deliberate — same PG eager-cast hazard avoided). The transitional NULL/empty branch is the **feature flag**: until services explicitly opt-in to setting `app.current_realm`, behaviour is identical to today.
  - Adds default-grants comment block at the top documenting the rollout sequence.
- Does **not** touch `rent_payments` (no policy, deliberately deny-all per V8 comment) — handled in T3.
- Adds a function `home_ai.set_realm(text)` that validates the argument is one of `('owner','work','family')` and `SET LOCAL`s it — single chokepoint for services to call.

**Acceptance**:
- After applying V65 with `app.current_realm` unset everywhere: `bash u52-realm-shadow-test.sh --check` returns exit 0 (transitional branch keeps behaviour identical).
- Manual probe: `SET LOCAL app.current_realm='work'; SELECT COUNT(*) FROM emails;` returns ≤ owner-realm count for the same table.
- Manual probe: `SET LOCAL app.current_realm='family'; SELECT COUNT(*) FROM vendor_invoice_inbox;` returns 0 (all 194 rows are realm=work).
- `\d+ emails` shows two policies — `entity_isolation` (permissive) and `realm_isolation` (restrictive).

---

### T3 — RLS coverage for realm-bearing tables without a policy (~45 min)

**Realm**: cross-cutting (every table is in some realm; we're filling the gaps).

**Why**: 92 tables now carry `realm`, only 43 are RLS-policied. The other 49 (workforce_*, weather_*, email_tasks, bot_feedback, classifier views, etc.) currently leak across realms because they have neither entity_isolation nor realm_isolation. A WORK login would see family rows on `email_tasks` if it queried before R5 ingest-tagging lands.

**Build**:
- `postgres/migrations/V65b__realm_rls_coverage.sql`:
  - For each of the 49 tables without RLS: `ALTER TABLE … ENABLE ROW LEVEL SECURITY` + `CREATE POLICY realm_isolation ON <t> AS PERMISSIVE FOR ALL USING (<same CASE as T2>)`. PERMISSIVE here (not RESTRICTIVE) because there is no co-existing `entity_isolation` to AND against.
  - Excludes the 11 framework tables explicitly listed in the V64 comment block (audit_log, system_alerts, etc.) which are intentionally cross-realm OWNER-only catalog.
  - For each excluded table, asserts via a `DO` block that `realm = 'owner'` for all rows (fail-loud if R1 missed one).
- `rent_payments` gets its long-promised join-based policy:
  ```sql
  CREATE POLICY rent_payments_via_tenancy ON rent_payments AS PERMISSIVE FOR ALL
  USING (EXISTS (
    SELECT 1 FROM tenancies t
     WHERE t.id = rent_payments.tenancy_id
       AND CASE
             WHEN current_setting('app.current_realm', true) = 'owner' THEN TRUE
             WHEN current_setting('app.current_realm', true) IN ('work','family')
                  THEN t.realm = current_setting('app.current_realm', true)
                       OR t.realm = 'shared'
             ELSE TRUE  -- transitional
           END
  ));
  ```
  Same transitional NULL-branch rule.

**Acceptance**:
- `SELECT COUNT(DISTINCT tablename) FROM pg_policies WHERE schemaname='public';` rises from 43 → ≥ 92 (or 81 if the 11 framework tables stay catalog-only — confirm count in plan-execution).
- Shadow harness check still green.
- Manual: `SET LOCAL app.current_realm='work'; SELECT * FROM rent_payments LIMIT 1;` returns 0 rows (rent_payments are FAMILY-realm by tenancy).

---

### T4 — `query_whitelist.realm` column + bot-side check (~30 min)

**Realm**: cross-cutting (query_whitelist is read by bot-responder which serves both WORK and FAMILY callers).

**Why**: per [[realm-split-architecture]] layer 5 — bot queries should fail at the whitelist, not at RLS, so the rejection is clean and observable. RLS-filtered-to-zero looks like "no data" to the user; whitelist-rejected logs a `query_rejections` row that's diagnosable.

**Build**:
- `postgres/migrations/V66__query_whitelist_realm.sql`:
  - Adds `allowed_realms text[]` column to `query_whitelist` (NOT NULL DEFAULT `'{owner}'`, then immediately re-seeded per existing query's data scope).
  - Adds `realm text` column to `query_rejections` capturing the caller's realm at rejection time.
- `services/bot-responder/main.py`:
  - Wherever `query_whitelist` is consulted (find via `grep -rn 'query_whitelist' services/bot-responder/`), add an `if caller_realm not in row.allowed_realms` rejection branch that writes to `query_rejections` with reason=`realm_not_allowed`.
- One-shot data: review the current ~40 query_whitelist rows by content and assign sensible `allowed_realms` arrays (most pub/cashflow queries → `{work,owner}`; family/child queries → `{family,owner}`; cross-realm KPIs → `{owner}`).

**Acceptance**:
- `SELECT name, allowed_realms FROM query_whitelist ORDER BY name;` shows non-default values for every row.
- Synthetic test: bot-responder receives a WORK-realm `caller_realm` header with a query name flagged `{family,owner}` → returns rejection, writes a `query_rejections` row with `realm='work'`.

---

### T5 — build-dashboard realm middleware (off by default) (~45 min)

**Realm**: cross-cutting (middleware fires on every request).

**Why**: this is the R4-partial piece that R2 needs *now* — services have to be able to set `app.current_realm` per request, even before Auth (R3) lands. We ship the plumbing dormant: `REALM_ENFORCE=0` (env, default) means every request runs as OWNER (same as today). `REALM_ENFORCE=1` makes the middleware read `X-Realm` from the request (set by Authelia + Caddy once R3 lands) and call `home_ai.set_realm(...)` on the request's transaction.

**Build**:
- `build-dashboard/main.py`:
  - Add a FastAPI dependency `current_realm(request)` that:
    - Reads `REALM_ENFORCE` env (default `0`).
    - If `0`: returns `'owner'` (status quo).
    - If `1`: reads `X-Realm` header; rejects with 401 if missing/invalid; returns the value.
  - Add a `SET LOCAL app.current_realm = <realm>` call at the top of every DB transaction (centralise in the `get_db()` dependency).
- Same pattern in `services/bot-responder/main.py` so bot writes/reads run scoped.
- `docker-compose.yml`: add `REALM_ENFORCE=0` to build-dashboard and bot-responder environment blocks, with a comment pointing at this sprint.
- One **integration test** under `/home_ai/scripts/`:
  - `u52-realm-middleware-smoke.sh` — flips `REALM_ENFORCE=1` for build-dashboard only (via `docker compose run --rm -e REALM_ENFORCE=1` if practical, else a temp override file), hits `/api/snapshot` with `X-Realm: work` and `X-Realm: family`, asserts both return non-error AND that family-side returns no pub revenue. Restores `REALM_ENFORCE=0` before exit.

**Acceptance**:
- `docker compose config | grep REALM_ENFORCE` shows the env var on both services.
- `bash u52-realm-middleware-smoke.sh` passes.
- With `REALM_ENFORCE=0`, all existing dashboards return identical data to pre-sprint (regression-free).

---

### T6 — Audit view + Telegram pulse (~20 min)

**Realm**: owner (audit infrastructure).

**Build**:
- `postgres/migrations/V66b__realm_audit_violations.sql`:
  - Creates `v_realm_audit_violations` — rows where `realm` disagrees with `entity_id`'s expected realm (entity 1 → work; entities 2/3/4 → family). Should be empty post-R1 but useful guardrail going forward.
  - Adds `v_realm_policy_coverage` — joins `pg_tables` with `pg_policies` filtered to public schema, shows which tables still lack a policy. Acceptance gate.
- Telegram pulse at end of sprint via existing `telegram_outbox`:
  - `R2 shipped: <N> tables now realm-policied, <M> framework tables OWNER-only, REALM_ENFORCE=0 (dormant), shadow-test green, audit-violations=0.`

**Acceptance**:
- `SELECT COUNT(*) FROM v_realm_audit_violations;` returns 0.
- Telegram message received.

---

### T7 — STATE.md regen + sprint exit (~10 min)

**Realm**: owner.

**Build**:
- Regenerate `/home_ai/STATE.md` reflecting:
  - R1 + R2 both shipped
  - 92/92 (or 81/81 if framework-table count holds) tables realm-policied
  - REALM_ENFORCE flag and what flips it to live
  - Outstanding realm work: R3 (blocked on tailscale-cert), R5 (ingest tagging), R6 (bot/AI scope), R7 (backup)
- Update `data/tasks.yaml` and `data/debt.yaml`:
  - Resolve "R1 unenforced" item
  - Add "R3 awaiting tailscale-cert FQDN" debt item if not already present
- Single short commit on a fresh branch `u52-realm-r2-rls`:
  - `git add postgres/migrations/V65*.sql postgres/migrations/V66*.sql services/bot-responder/main.py build-dashboard/main.py docker-compose.yml scripts/u52-*.sh data/realm-shadow-baseline.json STATE.md data/tasks.yaml data/debt.yaml`
  - Per [[feedback_homeai_pre_push_scan]] — run the entropy scan on the staged tree before pushing.

**Acceptance**:
- Commit lands locally.
- Push deferred to user (don't auto-push security-sensitive RLS changes).

## Sequence + acceptance

| # | Track                          | Effort | Independent? | Gate before next |
|---|--------------------------------|--------|--------------|------------------|
| 1 | Shadow harness                 | 45m    | yes          | Baseline JSON written, --check green |
| 2 | V65 layered realm policy       | 60m    | needs T1     | Shadow --check green; manual probes pass |
| 3 | V65b RLS coverage              | 45m    | needs T2     | Policy count ≥ 92; rent_payments family-scoped |
| 4 | query_whitelist.realm          | 30m    | needs T2     | Synthetic rejection test passes |
| 5 | Dashboard middleware           | 45m    | needs T2     | Smoke test passes; default-off regression-free |
| 6 | Audit views + Telegram         | 20m    | needs T3,T5  | violations=0; Telegram sent |
| 7 | STATE + tasks + commit         | 10m    | needs T6     | Commit on u52-realm-r2-rls branch |

**Total est**: ~4h 15m. T1 is the hard prerequisite — every subsequent track relies on its baseline. T4 and T5 can run in parallel after T2.

## What this sprint does NOT do

- **R3 Auth**: Authelia forward_auth + identity-to-realm mapping. Blocked on tailscale-cert FQDN ([[feedback_authelia_cookie_domain]]) — needs Jo at the box.
- **R5 Ingest**: google-fetch tagging realm at fetch by mailbox-of-receipt. Folded into U53.
- **R6 Bot/AI**: realm-scoped Haiku/Sonnet call-site scoping. Folded into U54 once query_whitelist.realm is live.
- **R7 Backup**: realm-scoped pg_dump for selective restore. Folded into U55.
- **Switching REALM_ENFORCE to 1**: requires R3 first, otherwise every request lacks an `X-Realm` header and rejects 401.
- **U50 Settle the Books**: feedback applier, per-site cost, due-date Haiku, stale-ack — explicitly deferred to U53 so realm work lands first while V64 is fresh in mind.
- **U51 Jo-input catch-up**: cafe vendors, Xero, vehicles, Companies House — independent of realm, needs Jo at keyboard, queued for next attended session.

## Follow-on sprints

- **U53 — Realm R5 (ingest tagging) + U50 Settle the Books bundle**: 4h autonomous. R5 piece is small (google-fetch mailbox→realm map + V67 making `vendor_invoice_inbox.realm` immutable-without-owner-override). Bundled with U50's classifier/cost/due-date work so the run is the right size.
- **U54 — Realm R6 (bot/AI scope)**: bot-responder and classifier respect `caller_realm`; Haiku/Sonnet prompts include realm context. 2-3h autonomous, after U53.
- **U55 — Realm R7 (backup) + ci-autofix**: realm-scoped pg_dump path; small CI tidy. ~2h.
- **U56 — Realm R3+R4 (Auth, in-person)**: tailscale-cert FQDN, finish Authelia forward_auth, flip `REALM_ENFORCE=1`. Needs Jo at the box; bundled with the existing in-person checklist from U51 T7.

## Abort criteria

Per discipline rule #9, if any of the following triggers — restore stable state, document, hand to fresh session:
- 4th attempt at the policy expression in T2 without a clean shadow-test result.
- More than 5 tables in T3 fail their realm-vs-entity_id consistency assertion (would indicate R1 missed a column population path — needs investigation, not iteration).
- T5 middleware breaks an existing dashboard at `REALM_ENFORCE=0` (regression — should be physically impossible if the env-gate is correct; if it isn't, the gate is wrong, not the policy).

Reply `go` to start; this is a single contiguous autonomous run with a Telegram pulse at each track boundary.
