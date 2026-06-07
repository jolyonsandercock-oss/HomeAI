# Frontend Security Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Close the homeai-frontend auth/RLS holes from Codex's 2026-06-07 review, and extend `scripts/audit-invariants.py` to cover the TypeScript frontend (the blind spot that let these through).

**Architecture:** The frontend is a Next.js app connecting as `homeai_readonly` and relying on (a) Authelia/Caddy forward_auth for identity and (b) `home_ai.set_realm()` + RLS for data scoping. Both are partly bypassable today: the service is published on `0.0.0.0:3003`, trusts a spoofable `Remote-Groups` header, and several routes call `set_realm()` outside a transaction so the realm is discarded before the query runs.

**Tech Stack:** Next.js (route handlers), node-postgres (`pg` Pool), PostgreSQL RLS, Caddy + Authelia, Docker Compose.

**Verification harness:** `python3 scripts/audit-invariants.py` (extended in Task 7) plus manual request tests.

---

## Task 1: F-FE1 — stop trusting spoofable identity headers (HIGH)

**Why:** `lib/realm.ts:32` derives realm from the `Remote-Groups` request header; `docker-compose.yml:584` publishes the app on `0.0.0.0:3003`. Anyone who can reach the host on :3003 (LAN, or off-tailnet if firewall is open) can send `Remote-Groups: owner` and get owner-realm data. The code comment already admits this ("IP backdoor … header can't be spoofed off-tailnet").

**Files:** `docker-compose.yml:584`, Caddy config (`security/.../Caddyfile` or compose), `services/homeai-frontend/lib/realm.ts`

- [ ] **Step 1:** Bind the published port to the tailnet IP (matches the block-form services already doing this). Change `ports: ["3003:3000"]` → `ports: ["100.104.82.53:3003:3000"]` (or `127.0.0.1:3003:3000` if only Caddy on-host should reach it).
- [ ] **Step 2:** In Caddy, **strip inbound `Remote-*` headers** before the request hits the app, and only re-inject them from Authelia's `/api/verify` response. Confirm the forward_auth block does `header_up -Remote-Groups` (delete) then copies the verified value.
- [ ] **Step 3:** Remove or authenticate the "IP backdoor" path referenced in `realm.ts` so there is no route that reaches the app without forward_auth.
- [ ] **Step 4: Verify** — from a non-proxy host on the tailnet: `curl -H 'Remote-Groups: owner' http://<host>:3003/app/api/...` must NOT return owner data (expect `work` default or 403). Via Caddy with a real owner session, owner data returns.
- [ ] **Step 5: Commit** `git commit -m "fix(frontend): bind to tailnet, strip spoofable Remote-* headers (F-FE1)"`

---

## Task 2: F-FE2 — route ALL frontend DB access through withRealm (HIGH)

**Why:** `home_ai.set_realm()` uses `set_config(..., is_local=true)` = **SET LOCAL**. Several routes do `const client = await p.connect(); await client.query("SELECT home_ai.set_realm('owner')"); /* then INSERT/UPDATE */` with **no `BEGIN`**. Each `query()` is its own autocommit transaction, so the realm is set and discarded in one statement; the following write runs with `app.current_realm` = NULL (and no `app.current_entity`). `lib/db.ts:91` already has a correct `withRealm()` wrapper (BEGIN → set_realm → fn → COMMIT) — these routes just don't use it.

Confirmed offenders (raw `connect()` + `set_realm` with no tx, or no realm at all):
`app/api/feedback/line/route.ts`, `app/api/dinner/remind/route.ts`, `app/api/categorise/vendor/route.ts`, `app/api/email/task/route.ts`, `app/api/snag/submit/route.ts`, `app/api/snag/upload/route.ts`, `app/api/snag/status/route.ts`, `app/api/breakfast/submit/route.ts`.
(Note: `lib/db.ts:94-95` cited by Codex are *inside* `withRealm` — those are correct, not violations.)

**Files:** the routes above; `lib/db.ts` (extend `withRealm` to also set entity)

- [ ] **Step 1:** Extend `withRealm` to set the entity GUC too, so callers get both in one tx:

```ts
// lib/db.ts — set realm AND entity transaction-locally
async function withRealm<T>(realm: string, fn: (c: PoolClient) => Promise<T>,
                            entity = '1'): Promise<T> {
  const client = await pool().connect();
  try {
    await client.query('BEGIN');
    await client.query('SELECT home_ai.set_realm($1)', [realm]);
    await client.query("SELECT set_config('app.current_entity', $1, true)", [entity]);
    const out = await fn(client);
    await client.query('COMMIT');
    return out;
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
}
```

- [ ] **Step 2:** Convert each offending route from hand-rolled `connect()` to `withRealm(realm, async (client) => { ...all queries... }, entity)`. Example for `feedback/line/route.ts`:

```ts
// before: const client = await p.connect(); try { await client.query(`SELECT home_ai.set_realm('owner')`); ... }
return withRealm('owner', async (client) => {
  const lineRows = await client.query(/* ...unchanged... */);
  // ...insert + update, all on this client, inside the same tx...
}, /* entity */ '1');
```

- [ ] **Step 3:** For routes calling SECURITY DEFINER functions (`snag/submit` → `home_ai.insert_snag`), still wrap in `withRealm` so the function body sees the correct realm/entity.
- [ ] **Step 4: Verify** — extended checker (Task 7) reports no raw `connect()`+`set_realm` outside `withRealm`; manually, a `work`-session request to an owner-only route returns no owner rows.
- [ ] **Step 5: Commit** `git commit -m "fix(frontend): all DB access via withRealm tx (realm+entity) (F-FE2)"`

---

## Task 3: F-FE3 — default-deny RLS when realm is unset (HIGH once T2 lands; MED now)

**Why:** `V237__snag_inbox_realm_isolation.sql` returns `true` (allow ALL rows) when `app.current_realm` IS NULL or `''`. Combined with Task 2's missing-realm bug, snag reads/writes currently run allow-all. Same permissive-null trap as the `RLS SET ROLE drops GUC defaults` incident.

**Files:** new migration `postgres/migrations/V247__realm_policy_default_deny.sql`; audit other realm policies first.

- [ ] **Step 1:** Find every policy with the permissive-null branch: `grep -rl "current_setting('app.current_realm', true) IS NULL" postgres/migrations/`. List them — fix all, not just snag_inbox.
- [ ] **Step 2:** Write `V247` redefining each policy so the NULL/empty branch is **`false`** (or only `owner` gets all). For snag_inbox:

```sql
-- V247: realm policies default-deny when realm is unset (was allow-all).
DROP POLICY IF EXISTS snag_inbox_realm_isolation ON snag_inbox;
CREATE POLICY snag_inbox_realm_isolation ON snag_inbox
  USING (
    CASE current_setting('app.current_realm', true)
      WHEN 'owner'    THEN true
      WHEN 'work'     THEN realm = ANY (ARRAY['work','shared'])
      WHEN 'personal' THEN realm = ANY (ARRAY['personal','shared'])
      ELSE false          -- NULL/empty/unknown → deny
    END
  )
  WITH CHECK ( /* same CASE */ );
```

- [ ] **Step 3:** Apply migration to the live DB (kill-switch check first), confirm snag UI still works for an owner session and returns nothing for an unset-realm connection.
- [ ] **Step 4: Verify** `psql` as a test role with no realm set → `SELECT count(*) FROM snag_inbox` returns 0.
- [ ] **Step 5: Commit** `git commit -m "fix(rls): realm policies default-deny on unset realm (F-FE3)"`

---

## Task 4: F-FE4 — harden the snag image endpoint (LOW)

**Why:** `app/api/snag/image/route.ts` blocks only `..` and always returns `image/png`. `path.join("/tmp/snags", file)` contains absolute traversal (join doesn't honour a leading-slash second arg), so the risk is limited, but there's no filename allowlist or content-type derivation.

**Files:** `app/api/snag/image/route.ts`

- [ ] **Step 1:** Reject anything but generated basenames and derive the content type:

```ts
const file = req.nextUrl.searchParams.get("file") ?? "";
if (!/^[0-9]+-[a-z0-9]{6}\.(png|jpe?g|webp)$/.test(file)) {
  return NextResponse.json({ error: "invalid" }, { status: 400 });
}
const ext = file.split(".").pop()!;
const mime = { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", webp: "image/webp" }[ext]!;
const buf = await readFile(join("/tmp/snags", file));
return new NextResponse(buf, { headers: { "Content-Type": mime, "Cache-Control": "max-age=3600" } });
```

- [ ] **Step 2: Verify** valid name serves; `../`, absolute paths, and odd extensions 400. **Commit.**

---

## Task 5: F-FE5 — fix the homeai_readonly misnomer (LOW–MED)

**Why:** `V134` grants `INSERT/UPDATE` on `sandbox_comments`/`sandbox_layout` to `homeai_readonly`, and the frontend connects via `POSTGRES_READONLY_URL` as that role. The grants are narrow (2 sandbox tables, intentional), so this is a naming/clarity hole, not broad exposure — but the name defeats least-privilege reasoning.

**Files:** new migration; `docker-compose.yml:585`; `lib/db.ts:17`

- [ ] **Step 1:** Decide: rename the role to `homeai_frontend` (reflves read + narrow sandbox writes) OR split a true-readonly role from a `homeai_sandbox_writer`. Recommended: rename, since the grant set is already minimal.
- [ ] **Step 2:** Migration to `ALTER ROLE homeai_readonly RENAME TO homeai_frontend;` (or create the split), update the DSN env var + Vault `secret/postgres-roles`, update `lib/db.ts`.
- [ ] **Step 3: Verify** frontend still reads and sandbox writes still work. **Commit.**

---

## Task 6: F-FE6 — narrow homeai_pipeline grants (MED, ties to U151b)

**Why:** `V246` grants `SELECT/INSERT/UPDATE/DELETE ON ALL TABLES` (+ default privileges) to `homeai_pipeline`. RLS still row-filters, but the table-level write surface is the whole schema. This belongs with the superuser→scoped-role migration (U151b) — do it there, not standalone, so the grant-gap audit produces per-table grants in one pass.

- [ ] Track in the U151b plan: replace blanket grants with per-table grants derived from the grant-gap audit, or move writes behind audited `SECURITY DEFINER` functions with narrow `EXECUTE`. Verify with `INV-PG-SUPERUSER`/`INV-ENTITY-GUC` clean.

---

## Task 7: F-FE7 — triage secret-bearing files on disk (MED)

**Why:** AGENTS says "Vault only." Codex found `/home_ai/.env`, `services/homeai-vault-agent/secrets/secret_id`, `security/authelia-v2/users_database.yml`. **Nuance — not all are violations:**
- `vault-agent/secrets/secret_id` — the AppRole SecretID that bootstraps Vault Agent; chicken-and-egg, **must** exist on disk (ensure `0600`, root-owned, gitignored).
- `authelia-v2/users_database.yml` — argon2 password *hashes*, not plaintext; this is how Authelia works. Keep, but confirm hashes not plaintext and file perms tight.
- `.env` with `VAULT_TOKEN`, `POSTGRES_PASSWORD`, etc. — this is the real drift (matches the pre-push-scan memory). Plaintext tokens that should be Vault-injected.

**Files:** `/home_ai/.env`, perms on the other two.

- [ ] **Step 1:** Confirm none are git-tracked: `git ls-files | grep -E '\.env$|secret_id|users_database'` (Codex says clean — re-verify).
- [ ] **Step 2:** For `.env`: identify which services still read it vs Vault. Migrate those to Vault-agent injection; reduce `.env` to non-secret config or delete. Rotate `VAULT_TOKEN` if it has been broadly readable.
- [ ] **Step 3:** `chmod 600` + verify ownership on `secret_id` and `users_database.yml`; ensure all three are in `.gitignore` and the pre-push entropy scan covers them.
- [ ] **Step 4: Verify** services start with secrets sourced from Vault; pre-push scan passes. **Commit** (config only — never the secrets).

---

## Task 8: extend the checker to cover the frontend (the blind spot)

**Why:** `scripts/audit-invariants.py` scans `services/*.py` + n8n + compose, but **not** `.ts`/`.tsx`. Every finding above was invisible to it. Add frontend checks so they can't regress.

**Files:** `scripts/audit-invariants.py`

- [ ] **Step 1:** Add a `check_frontend()` that scans `services/homeai-frontend/app/api/**/route.ts` for:
  - `await pool().connect()` / `p.connect()` followed by `set_realm` **without** a `BEGIN` / not wrapped in `withRealm` → FAIL (realm discarded).
  - raw `INSERT INTO` / `UPDATE … SET` in a route file that doesn't go through `withRealm` → WARN.
  - `req.headers.get('remote-groups')` used to grant access without a note that Caddy strips inbound → WARN (header-trust).
- [ ] **Step 2:** Add a SQL-migration check: any `CREATE POLICY` whose `current_setting('app.current_realm', true) IS NULL` branch yields `true` → FAIL (permissive-null).
- [ ] **Step 3:** Verify the new checks fire on today's offenders, then clear after Tasks 1–3. **Commit.**

---

## Self-review

- **Coverage:** F-FE1 (T1), set_realm-outside-tx + missing-entity (T2), snag_inbox allow-all (T3), image validation (T4), readonly misnomer (T5), pipeline grants (T6→U151b), secret files (T7), checker gap (T8).
- **Severity adjustments vs Codex:** readonly-writes downgraded to LOW–MED (grants are narrow/intentional, it's a naming issue); snag image downgraded to LOW (`..` block + join semantics contain traversal; real gap is MIME/allowlist); snag_inbox raised toward HIGH because it compounds with T2.
- **False positives noted:** `lib/db.ts:94-95` are inside the correct `withRealm` wrapper, not violations.
- **Ordering:** T1+T2+T3 first (they compound into the live auth/RLS hole), then T8 to lock the gate, then T4/T5/T7; T6 folds into U151b.
