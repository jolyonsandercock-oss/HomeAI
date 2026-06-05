# Counterparty Registry (P1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a deterministic `counterparties` registry from the `emails` table — org = domain, person = address — with heuristic noise-flagging and fuzzy financial linking, as the foundation for counterparty dossiers (U242 T2 / U235 Stage 4).

**Architecture:** A migration creates the `counterparties` table + RLS (mirroring V227). A PL/pgSQL function `home_ai.build_counterparty_registry()` does an idempotent upsert from `emails`, then flags automated senders, links to vendors via `pg_trgm`, and computes a signal score. A thin bash runner invokes it; a SQL verification script asserts correctness. No LLM in this phase.

**Tech Stack:** PostgreSQL 16 (`home_ai` schema, `pg_trgm`), bash runner via `docker exec homeai-postgres psql`. **No pytest harness exists in this repo** — "tests" are SQL verification assertions that `RAISE EXCEPTION` on failure (psql returns non-zero), the project's established pattern.

**Spec:** `docs/superpowers/specs/2026-06-05-counterparty-cultural-memory-design.md` (§3, §4).

---

## File Structure

- Create: `postgres/migrations/V228__u242_counterparty_registry.sql` — table, indexes, RLS, the build function.
- Create: `scripts/build-counterparty-registry.sh` — idempotent runner (`SELECT home_ai.build_counterparty_registry()`).
- Create: `scripts/verify-counterparty-registry.sql` — assertion suite (own-domain excluded, real orgs kept, automated flagged, realm arrays, person→org links, idempotency).

All three change together (one responsibility: the registry), committed across the tasks below.

---

## Conventions for every task

- Apply a migration: `docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 -f - < postgres/migrations/V228__u242_counterparty_registry.sql`
  (the migration is written idempotently — `CREATE ... IF NOT EXISTS`, `CREATE OR REPLACE` — so re-applying after each task is safe).
- Run a query: `docker exec -i homeai-postgres psql -U postgres -d homeai -tAc "<sql>"`.
- A verification assertion that fails must make psql exit non-zero. Use:
  ```sql
  DO $$ BEGIN IF NOT (<condition>) THEN RAISE EXCEPTION '<message>'; END IF; END $$;
  ```

---

### Task 1: Migration skeleton — `counterparties` table + indexes + RLS

**Files:**
- Create: `postgres/migrations/V228__u242_counterparty_registry.sql`
- Create: `scripts/verify-counterparty-registry.sql`

- [ ] **Step 1: Write the failing verification**

Create `scripts/verify-counterparty-registry.sql` with just the table-shape assertion for now:

```sql
-- verify-counterparty-registry.sql — assertions; psql exits non-zero on any failure.
\set ON_ERROR_STOP on

DO $$ BEGIN
  IF to_regclass('public.counterparties') IS NULL THEN
    RAISE EXCEPTION 'counterparties table does not exist';
  END IF;
END $$;

DO $$
DECLARE missing text;
BEGIN
  SELECT string_agg(c, ', ') INTO missing
  FROM unnest(ARRAY['id','kind','display_name','domain','primary_email','addresses',
                    'parent_org_id','realms','is_automated','email_count','first_seen',
                    'last_seen','linked_vendor','linked_confidence','signal_score',
                    'on_watchlist','created_at','updated_at']) AS c
  WHERE c NOT IN (SELECT column_name FROM information_schema.columns
                  WHERE table_name='counterparties');
  IF missing IS NOT NULL THEN RAISE EXCEPTION 'counterparties missing columns: %', missing; END IF;
END $$;

DO $$ BEGIN
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE relname='counterparties') THEN
    RAISE EXCEPTION 'RLS not enabled on counterparties';
  END IF;
END $$;
```

- [ ] **Step 2: Run it to verify it fails**

Run: `docker exec -i homeai-postgres psql -U postgres -d homeai -f - < scripts/verify-counterparty-registry.sql`
Expected: FAIL — `ERROR: counterparties table does not exist`, psql exit code non-zero.

- [ ] **Step 3: Write the migration**

Create `postgres/migrations/V228__u242_counterparty_registry.sql`:

```sql
-- V228 — U242 T2: counterparty registry (deterministic, no LLM).
-- org = email domain, person = address. Built by home_ai.build_counterparty_registry().
BEGIN;

CREATE TABLE IF NOT EXISTS counterparties (
  id                bigserial PRIMARY KEY,
  kind              text NOT NULL CHECK (kind IN ('org','person')),
  display_name      text NOT NULL,
  domain            text,
  primary_email     text,
  addresses         text[] NOT NULL DEFAULT '{}',
  parent_org_id     bigint REFERENCES counterparties(id) ON DELETE SET NULL,
  realms            text[] NOT NULL DEFAULT '{}',
  is_automated      boolean NOT NULL DEFAULT false,
  email_count       integer NOT NULL DEFAULT 0,
  first_seen        timestamptz,
  last_seen         timestamptz,
  linked_vendor     text,
  linked_confidence real,
  signal_score      real NOT NULL DEFAULT 0,
  on_watchlist      boolean NOT NULL DEFAULT false,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

-- Identity keys: an org is unique by domain, a person by primary_email.
CREATE UNIQUE INDEX IF NOT EXISTS counterparties_org_key
  ON counterparties (domain) WHERE kind = 'org';
CREATE UNIQUE INDEX IF NOT EXISTS counterparties_person_key
  ON counterparties (primary_email) WHERE kind = 'person';
CREATE INDEX IF NOT EXISTS counterparties_signal ON counterparties (signal_score DESC);
CREATE INDEX IF NOT EXISTS counterparties_realms ON counterparties USING gin (realms);

-- RLS: mirror V227 search_vectors — open base SELECT + restrictive realm narrow.
-- realms is an array here, so use overlap (&&) instead of equality.
ALTER TABLE counterparties ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS base_access ON counterparties;
CREATE POLICY base_access ON counterparties FOR SELECT USING (true);

DROP POLICY IF EXISTS realm_isolation ON counterparties;
CREATE POLICY realm_isolation ON counterparties AS RESTRICTIVE USING (
  CASE
    WHEN current_setting('app.current_realm', true) = 'owner'    THEN true
    WHEN current_setting('app.current_realm', true) = 'work'     THEN realms && ARRAY['work','shared']
    WHEN current_setting('app.current_realm', true) = 'personal' THEN realms && ARRAY['personal','shared']
    WHEN current_setting('app.current_realm', true) IS NULL
      OR current_setting('app.current_realm', true) = ''         THEN true
    ELSE false
  END);
GRANT SELECT ON counterparties TO homeai_readonly;

COMMIT;
```

- [ ] **Step 4: Apply the migration and run the verification**

Run:
```bash
docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 -f - < postgres/migrations/V228__u242_counterparty_registry.sql
docker exec -i homeai-postgres psql -U postgres -d homeai -f - < scripts/verify-counterparty-registry.sql
```
Expected: migration `COMMIT`; verification prints `DO` lines and exits 0 (no EXCEPTION).

- [ ] **Step 5: Commit**

```bash
git add postgres/migrations/V228__u242_counterparty_registry.sql scripts/verify-counterparty-registry.sql
git commit -m "U242 P1: counterparties table + RLS (mirror V227)"
```

---

### Task 2: Build function — orgs + people upsert from emails

**Files:**
- Modify: `postgres/migrations/V228__u242_counterparty_registry.sql` (add the function before `COMMIT;`)
- Modify: `scripts/verify-counterparty-registry.sql` (add population assertions)

- [ ] **Step 1: Write the failing verification**

Append to `scripts/verify-counterparty-registry.sql`:

```sql
-- Population assertions (require home_ai.build_counterparty_registry() to have run).
DO $$ BEGIN
  IF (SELECT count(*) FROM counterparties WHERE kind='org') < 100 THEN
    RAISE EXCEPTION 'expected >=100 org counterparties, got %',
      (SELECT count(*) FROM counterparties WHERE kind='org');
  END IF;
END $$;

-- Own domain must be excluded.
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM counterparties WHERE domain = 'malthousetintagel.com') THEN
    RAISE EXCEPTION 'own domain malthousetintagel.com must not be a counterparty';
  END IF;
END $$;

-- A known real vendor domain must be present as an org with a realm.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM counterparties
                 WHERE kind='org' AND domain='jrf.lls.com'
                   AND array_length(realms,1) >= 1 AND email_count > 0) THEN
    RAISE EXCEPTION 'expected jrf.lls.com org with realm + email_count';
  END IF;
END $$;

-- People link to their org by domain.
DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM counterparties p
    JOIN counterparties o ON o.kind='org' AND o.domain=p.domain
    WHERE p.kind='person' AND p.parent_org_id IS DISTINCT FROM o.id) THEN
    RAISE EXCEPTION 'person rows exist whose parent_org_id does not match their domain org';
  END IF;
END $$;
```

- [ ] **Step 2: Run to verify it fails**

Run: `docker exec -i homeai-postgres psql -U postgres -d homeai -f - < scripts/verify-counterparty-registry.sql`
Expected: FAIL — `function home_ai.build_counterparty_registry() does not exist` is not yet called, so the count assertion fails: `expected >=100 org counterparties, got 0`.

- [ ] **Step 3: Add the build function to the migration**

Insert before `COMMIT;` in `V228__u242_counterparty_registry.sql`:

```sql
-- Idempotent registry builder. Re-runnable; upserts orgs then people.
-- Own/internal domains to exclude live in the EXCLUDED_DOMAINS array.
CREATE OR REPLACE FUNCTION home_ai.build_counterparty_registry()
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  excluded_domains text[] := ARRAY['malthousetintagel.com'];
BEGIN
  -- 1. Orgs (one row per sender domain).
  INSERT INTO counterparties (kind, display_name, domain, addresses, realms,
                              email_count, first_seen, last_seen)
  SELECT 'org',
         COALESCE((array_agg(from_name ORDER BY received_at DESC)
                   FILTER (WHERE COALESCE(from_name,'') <> ''))[1], domain),
         domain,
         array_agg(DISTINCT addr),
         COALESCE(array_agg(DISTINCT realm) FILTER (WHERE realm IS NOT NULL), '{}'),
         count(*), min(received_at), max(received_at)
  FROM (
    SELECT lower(split_part(from_address,'@',2)) AS domain,
           lower(from_address)                   AS addr,
           from_name, realm, received_at
    FROM emails
    WHERE from_address LIKE '%@%'
      AND split_part(from_address,'@',2) <> ''
      AND lower(split_part(from_address,'@',2)) <> ALL (excluded_domains)
  ) s
  GROUP BY domain
  ON CONFLICT (domain) WHERE kind='org' DO UPDATE SET
    addresses    = EXCLUDED.addresses,
    realms       = EXCLUDED.realms,
    email_count  = EXCLUDED.email_count,
    first_seen   = EXCLUDED.first_seen,
    last_seen    = EXCLUDED.last_seen,
    display_name = EXCLUDED.display_name,
    updated_at   = now();

  -- 2. People (one row per sender address), linked to their domain's org.
  INSERT INTO counterparties (kind, display_name, domain, primary_email, addresses,
                              parent_org_id, realms, email_count, first_seen, last_seen)
  SELECT 'person',
         COALESCE(p.name, p.addr), p.domain, p.addr, ARRAY[p.addr],
         o.id, p.realms, p.n, p.fs, p.ls
  FROM (
    SELECT lower(from_address) AS addr,
           lower(split_part(from_address,'@',2)) AS domain,
           (array_agg(from_name ORDER BY received_at DESC)
            FILTER (WHERE COALESCE(from_name,'') <> ''))[1] AS name,
           COALESCE(array_agg(DISTINCT realm) FILTER (WHERE realm IS NOT NULL), '{}') AS realms,
           count(*) AS n, min(received_at) AS fs, max(received_at) AS ls
    FROM emails
    WHERE from_address LIKE '%@%'
      AND split_part(from_address,'@',2) <> ''
      AND lower(split_part(from_address,'@',2)) <> ALL (excluded_domains)
    GROUP BY addr, domain
  ) p
  LEFT JOIN counterparties o ON o.kind='org' AND o.domain = p.domain
  ON CONFLICT (primary_email) WHERE kind='person' DO UPDATE SET
    parent_org_id = EXCLUDED.parent_org_id,
    realms        = EXCLUDED.realms,
    email_count   = EXCLUDED.email_count,
    first_seen    = EXCLUDED.first_seen,
    last_seen     = EXCLUDED.last_seen,
    display_name  = EXCLUDED.display_name,
    updated_at    = now();
END;
$fn$;
```

- [ ] **Step 4: Apply migration, run the builder, verify**

Run:
```bash
docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 -f - < postgres/migrations/V228__u242_counterparty_registry.sql
docker exec -i homeai-postgres psql -U postgres -d homeai -c "SELECT home_ai.build_counterparty_registry();"
docker exec -i homeai-postgres psql -U postgres -d homeai -f - < scripts/verify-counterparty-registry.sql
```
Expected: builder returns `build_counterparty_registry | (void)`; verification exits 0.

- [ ] **Step 5: Commit**

```bash
git add postgres/migrations/V228__u242_counterparty_registry.sql scripts/verify-counterparty-registry.sql
git commit -m "U242 P1: registry build function (orgs + people upsert from emails)"
```

---

### Task 3: Automated-sender flagging

**Files:**
- Modify: `postgres/migrations/V228__u242_counterparty_registry.sql` (extend the function)
- Modify: `scripts/verify-counterparty-registry.sql`

- [ ] **Step 1: Write the failing verification**

Append to `scripts/verify-counterparty-registry.sql`:

```sql
-- Automated flagging: no-reply local-parts and single-address high-volume senders.
DO $$ BEGIN
  -- A single-address domain with huge volume (e.g. partners.collinsbookings.com) is automated.
  IF EXISTS (SELECT 1 FROM counterparties
             WHERE kind='org' AND domain='partners.collinsbookings.com' AND NOT is_automated) THEN
    RAISE EXCEPTION 'high-volume single-address sender not flagged automated';
  END IF;
  -- A real multi-human-address vendor must NOT be flagged automated.
  IF EXISTS (SELECT 1 FROM counterparties
             WHERE kind='org' AND domain='jrf.lls.com' AND is_automated) THEN
    RAISE EXCEPTION 'real vendor jrf.lls.com wrongly flagged automated';
  END IF;
  -- A no-reply person address is automated.
  IF EXISTS (SELECT 1 FROM counterparties
             WHERE kind='person' AND primary_email LIKE 'no-reply@%' AND NOT is_automated) THEN
    RAISE EXCEPTION 'no-reply person not flagged automated';
  END IF;
END $$;
```

- [ ] **Step 2: Run to verify it fails**

Run: `docker exec -i homeai-postgres psql -U postgres -d homeai -f - < scripts/verify-counterparty-registry.sql`
Expected: FAIL — `high-volume single-address sender not flagged automated` (is_automated still all false).

- [ ] **Step 3: Add flagging to the function**

Insert this block inside `home_ai.build_counterparty_registry()`, immediately before the final `END;`:

```sql
  -- 3. Flag automated senders (heuristic; flagged, never deleted).
  UPDATE counterparties c SET is_automated = true, updated_at = now()
  WHERE NOT c.is_automated AND (
        -- noisy local-parts
        split_part(COALESCE(c.primary_email, ''), '@', 1) ~*
          '^(no-?reply|do-?not-?reply|notifications?|mailer|bounce|updates?|news|newsletter|marketing|alerts?|postmaster|mailer-daemon)$'
        -- single-address org pumping volume
     OR (c.kind='org' AND array_length(c.addresses,1) = 1 AND c.email_count > 50)
        -- known bulk ESP domains
     OR c.domain = ANY (ARRAY['sendgrid.net','mailchimp.com','mailgun.org','sparkpostmail.com',
                              'amazonses.com','sendgrid.com'])
  );
```

- [ ] **Step 4: Apply, rebuild, verify**

Run:
```bash
docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 -f - < postgres/migrations/V228__u242_counterparty_registry.sql
docker exec -i homeai-postgres psql -U postgres -d homeai -c "SELECT home_ai.build_counterparty_registry();"
docker exec -i homeai-postgres psql -U postgres -d homeai -f - < scripts/verify-counterparty-registry.sql
```
Expected: verification exits 0.

- [ ] **Step 5: Commit**

```bash
git add postgres/migrations/V228__u242_counterparty_registry.sql scripts/verify-counterparty-registry.sql
git commit -m "U242 P1: flag automated senders (no-reply, single-addr high-volume, bulk ESPs)"
```

---

### Task 4: Fuzzy financial linking (orgs → vendors)

**Files:**
- Modify: `postgres/migrations/V228__u242_counterparty_registry.sql` (extend the function)
- Modify: `scripts/verify-counterparty-registry.sql`

- [ ] **Step 1: Write the failing verification**

Append to `scripts/verify-counterparty-registry.sql`:

```sql
-- Financial linking: at least some orgs should match a vendor; confidence in [0,1];
-- links are reviewable (low-confidence allowed) but never fabricated.
DO $$ BEGIN
  IF (SELECT count(*) FROM counterparties WHERE linked_vendor IS NOT NULL) = 0 THEN
    RAISE EXCEPTION 'no counterparties linked to any vendor — linking did not run';
  END IF;
  IF EXISTS (SELECT 1 FROM counterparties
             WHERE linked_vendor IS NOT NULL
               AND (linked_confidence IS NULL OR linked_confidence < 0 OR linked_confidence > 1)) THEN
    RAISE EXCEPTION 'linked_confidence out of [0,1] or null on a linked row';
  END IF;
END $$;
```

- [ ] **Step 2: Run to verify it fails**

Run: `docker exec -i homeai-postgres psql -U postgres -d homeai -f - < scripts/verify-counterparty-registry.sql`
Expected: FAIL — `no counterparties linked to any vendor — linking did not run`.

- [ ] **Step 3: Add linking to the function**

Insert inside `home_ai.build_counterparty_registry()`, before the final `END;` (after the flagging block):

```sql
  -- 4. Best-effort fuzzy link orgs -> vendor_invoice_inbox.vendor_name (pg_trgm).
  --    Reviewable, not authoritative: store best match + similarity as confidence.
  WITH vendors AS (
    SELECT DISTINCT vendor_name FROM vendor_invoice_inbox
    WHERE COALESCE(vendor_name,'') <> ''
  ),
  best AS (
    SELECT c.id,
           v.vendor_name,
           similarity(lower(c.display_name), lower(v.vendor_name)) AS sim,
           row_number() OVER (PARTITION BY c.id
             ORDER BY similarity(lower(c.display_name), lower(v.vendor_name)) DESC) AS rn
    FROM counterparties c
    CROSS JOIN vendors v
    WHERE c.kind='org'
      AND similarity(lower(c.display_name), lower(v.vendor_name)) >= 0.35
  )
  UPDATE counterparties c
     SET linked_vendor = b.vendor_name,
         linked_confidence = b.sim,
         updated_at = now()
  FROM best b
  WHERE b.rn = 1 AND b.id = c.id;
```

- [ ] **Step 4: Apply, rebuild, verify**

Run:
```bash
docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 -f - < postgres/migrations/V228__u242_counterparty_registry.sql
docker exec -i homeai-postgres psql -U postgres -d homeai -c "SELECT home_ai.build_counterparty_registry();"
docker exec -i homeai-postgres psql -U postgres -d homeai -f - < scripts/verify-counterparty-registry.sql
```
Expected: verification exits 0. (Spot-check: `SELECT display_name, linked_vendor, round(linked_confidence::numeric,2) FROM counterparties WHERE linked_vendor IS NOT NULL ORDER BY linked_confidence DESC LIMIT 10;`)

- [ ] **Step 5: Commit**

```bash
git add postgres/migrations/V228__u242_counterparty_registry.sql scripts/verify-counterparty-registry.sql
git commit -m "U242 P1: fuzzy-link orgs to vendors via pg_trgm (reviewable confidence)"
```

---

### Task 5: Signal score + runner script + idempotency

**Files:**
- Modify: `postgres/migrations/V228__u242_counterparty_registry.sql` (extend the function)
- Create: `scripts/build-counterparty-registry.sh`
- Modify: `scripts/verify-counterparty-registry.sql`

- [ ] **Step 1: Write the failing verification**

Append to `scripts/verify-counterparty-registry.sql`:

```sql
-- signal_score populated for real orgs; eager-selection set is non-trivial.
DO $$ BEGIN
  IF (SELECT count(*) FROM counterparties WHERE signal_score > 0) = 0 THEN
    RAISE EXCEPTION 'signal_score never computed';
  END IF;
  -- The eager subset (T2 default: financial link OR >=20 emails OR watchlist, not automated)
  -- should be in a sane range for this corpus (~150-300).
  IF (SELECT count(*) FROM counterparties
      WHERE NOT is_automated
        AND (linked_vendor IS NOT NULL OR email_count >= 20 OR on_watchlist)) < 50 THEN
    RAISE EXCEPTION 'eager subset implausibly small';
  END IF;
END $$;
```

- [ ] **Step 2: Run to verify it fails**

Run: `docker exec -i homeai-postgres psql -U postgres -d homeai -f - < scripts/verify-counterparty-registry.sql`
Expected: FAIL — `signal_score never computed`.

- [ ] **Step 3: Add signal_score to the function**

Insert inside `home_ai.build_counterparty_registry()`, before the final `END;` (after linking):

```sql
  -- 5. signal_score: volume (log) + financial link bonus + recency bonus.
  UPDATE counterparties c SET signal_score = (
      ln(c.email_count + 1)
      + CASE WHEN c.linked_vendor IS NOT NULL THEN 2.0 ELSE 0 END
      + CASE WHEN c.last_seen > now() - interval '180 days' THEN 1.0 ELSE 0 END
      + CASE WHEN c.on_watchlist THEN 3.0 ELSE 0 END
    )::real,
    updated_at = now()
  WHERE NOT c.is_automated;
```

- [ ] **Step 4: Create the runner script**

Create `scripts/build-counterparty-registry.sh`:

```bash
#!/usr/bin/env bash
# build-counterparty-registry.sh — (re)build the counterparties registry. Idempotent.
# Safe to run from cron; pure SQL, no LLM. See docs/superpowers/specs/2026-06-05-*.
set -euo pipefail
docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 \
  -c "SELECT home_ai.build_counterparty_registry();"
echo "✓ counterparty registry built ($(docker exec -i homeai-postgres psql -U postgres -d homeai -tAc \
  "select count(*) from counterparties"))"
```

Then: `chmod 0755 scripts/build-counterparty-registry.sh`

- [ ] **Step 5: Apply, run twice (idempotency), verify**

Run:
```bash
docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 -f - < postgres/migrations/V228__u242_counterparty_registry.sql
N1=$(docker exec -i homeai-postgres psql -U postgres -d homeai -tAc "SELECT home_ai.build_counterparty_registry(); SELECT count(*) FROM counterparties")
bash scripts/build-counterparty-registry.sh
N2=$(docker exec -i homeai-postgres psql -U postgres -d homeai -tAc "select count(*) from counterparties")
test "$N1" = "$N2" && echo "IDEMPOTENT: $N1 == $N2" || { echo "NOT IDEMPOTENT: $N1 != $N2"; exit 1; }
docker exec -i homeai-postgres psql -U postgres -d homeai -f - < scripts/verify-counterparty-registry.sql
```
Expected: `IDEMPOTENT: <n> == <n>` (second run doesn't change the row count); verification exits 0.

- [ ] **Step 6: Commit**

```bash
git add postgres/migrations/V228__u242_counterparty_registry.sql scripts/build-counterparty-registry.sh scripts/verify-counterparty-registry.sql
git commit -m "U242 P1: signal_score + idempotent runner + full verification suite"
```

---

### Task 6: RLS realm-isolation test

**Files:**
- Modify: `scripts/verify-counterparty-registry.sql`

- [ ] **Step 1: Write the failing verification**

Append to `scripts/verify-counterparty-registry.sql`:

```sql
-- A work-realm reader (homeai_readonly) must not see personal-only counterparties.
-- Simulate the readonly role under work realm and assert no personal-only rows leak.
DO $$
DECLARE leaked int;
BEGIN
  PERFORM set_config('app.current_realm', 'work', true);
  SET LOCAL ROLE homeai_readonly;
  SELECT count(*) INTO leaked FROM counterparties
   WHERE realms = ARRAY['personal'];        -- personal-only rows
  RESET ROLE;
  IF leaked > 0 THEN
    RAISE EXCEPTION 'work realm leaked % personal-only counterparties (RLS gap)', leaked;
  END IF;
END $$;
```

- [ ] **Step 2: Run to verify behaviour**

Run: `docker exec -i homeai-postgres psql -U postgres -d homeai -f - < scripts/verify-counterparty-registry.sql`
Expected: PASS if the RLS `realm_isolation` policy from Task 1 is correct (it is). If it FAILS, the policy's array-overlap branch is wrong — fix the policy in V228 (`realms && ARRAY['work','shared']`), re-apply, re-run.

- [ ] **Step 3: Commit**

```bash
git add scripts/verify-counterparty-registry.sql
git commit -m "U242 P1: RLS realm-isolation test (work cannot read personal-only counterparties)"
```

---

## Done criteria (P1)

- `counterparties` populated (~1,600 orgs + people), own domain excluded, automated flagged, vendors linked (reviewable confidence), signal_score set.
- `bash scripts/build-counterparty-registry.sh` is idempotent.
- `scripts/verify-counterparty-registry.sql` exits 0 (all assertions pass), including RLS isolation.
- **Next:** P2 plan (distillation worker + `counterparty_dossier`) — separate plan when P1 lands.
