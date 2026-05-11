# 2026-05-08 — rent_payments RLS design

## Context

`rent_payments` has RLS enabled but no policy → deny-all for non-superusers
(per V3 `restore_rls_policies.sql` exclusion list). It can't take the standard
`entity_isolation` policy because `rent_payments` has no `entity_id` column —
it derives entity from `tenancy_id → tenancies.property_id → properties.entity_id`.

This blocks the rent reconciliation pipeline (Phase 2 Step 14-15). Need a
policy in place before that work starts.

## Options

### Option A — JOIN-based policy (no schema change)

```sql
CREATE POLICY entity_isolation ON rent_payments
  USING (CASE
    WHEN current_setting('app.current_entity', true) = 'all' THEN TRUE
    WHEN current_setting('app.current_entity', true) ~ '^\d+$' THEN
      EXISTS (
        SELECT 1 FROM tenancies t
        WHERE t.id = rent_payments.tenancy_id
          AND t.entity_id = current_setting('app.current_entity', true)::int
      )
    ELSE FALSE
  END)
  WITH CHECK (CASE
    WHEN current_setting('app.current_entity', true) = 'all' THEN TRUE
    WHEN current_setting('app.current_entity', true) ~ '^\d+$' THEN
      EXISTS (
        SELECT 1 FROM tenancies t
        WHERE t.id = rent_payments.tenancy_id
          AND t.entity_id = current_setting('app.current_entity', true)::int
      )
    ELSE FALSE
  END);
```

**Pros**
- No schema changes
- `tenancies` remains the single source of truth for entity ownership
- DRY — one entity reference per tenant

**Cons**
- Every read evaluates an EXISTS subquery
- Policy harder to read; deviates from the simple-equality pattern used by
  the other 10 tables
- Index needed: `tenancies(id, entity_id)` — `id` is already PK, but adding
  `entity_id` to the index covers the EXISTS lookup
- Cross-table joins/aggregations that filter `rent_payments` by entity_id
  end up doing the lookup twice (once in policy, once in user query)

### Option B — Denormalise `entity_id` onto `rent_payments` (recommended)

Add an `entity_id` column to `rent_payments`, mirroring it from
`tenancies.entity_id` via a populate-on-insert trigger. Then apply the
standard `entity_isolation` policy (identical to all other tables).

**Pros**
- Policy matches the other 10 tables — one mental model, less surprise
- Faster (direct equality on indexed column, no subquery)
- Easier to query rent_payments by entity directly without join
- Trigger keeps `entity_id` in sync if tenancy ever moves between entities
  (rare but possible — e.g. internal transfer between Trading and Estates)

**Cons**
- Schema change (one column + index + trigger)
- Risk of drift if a tenancy is reassigned to a different entity *and*
  rent_payments rows are not updated — mitigated by trigger

## Decision

**Option B.** The pattern-consistency benefit and performance simplicity
outweigh the small migration cost (the table is small — Atlantic Road has
~7 properties so a few hundred rent_payments rows per year).

## Candidate migration

Filename: `postgres/migrations/V7__rent_payments_entity_id.sql`

```sql
-- V7__rent_payments_entity_id.sql
-- Adds entity_id to rent_payments (denormalised from tenancies.entity_id)
-- and applies the standard entity_isolation RLS policy.
--
-- Why: rent_payments inherits entity scope via tenancy_id → tenancies.property_id → properties.entity_id.
-- Adding the column directly enables the same simple policy used by every
-- other entity-scoped table. Trigger maintains consistency if a tenancy ever
-- changes entity (rare).
--
-- Idempotent: safe to re-run.

\set ON_ERROR_STOP on

-- 1. Add column (nullable initially, backfilled, then made NOT NULL)
ALTER TABLE rent_payments
  ADD COLUMN IF NOT EXISTS entity_id INT REFERENCES entities(id);

-- 2. Backfill from tenancies
UPDATE rent_payments rp
   SET entity_id = t.entity_id
  FROM tenancies t
 WHERE t.id = rp.tenancy_id
   AND rp.entity_id IS NULL;

-- 3. Enforce NOT NULL (only safe after backfill — fails loudly if any row
--    couldn't be filled, which would indicate a tenancy_id without a parent)
ALTER TABLE rent_payments
  ALTER COLUMN entity_id SET NOT NULL;

-- 4. Index for the policy + queries
CREATE INDEX IF NOT EXISTS idx_rent_payments_entity
  ON rent_payments (entity_id);

-- 5. Trigger to populate entity_id on INSERT/UPDATE (defence-in-depth)
CREATE OR REPLACE FUNCTION rent_payments_sync_entity_id()
RETURNS TRIGGER AS $$
BEGIN
  -- Only auto-populate if entity_id wasn't explicitly set
  IF NEW.entity_id IS NULL OR
     (TG_OP = 'UPDATE' AND NEW.tenancy_id IS DISTINCT FROM OLD.tenancy_id) THEN
    SELECT t.entity_id INTO NEW.entity_id
      FROM tenancies t
     WHERE t.id = NEW.tenancy_id;
    IF NEW.entity_id IS NULL THEN
      RAISE EXCEPTION 'tenancy_id % has no parent entity', NEW.tenancy_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS rent_payments_entity_sync ON rent_payments;
CREATE TRIGGER rent_payments_entity_sync
  BEFORE INSERT OR UPDATE ON rent_payments
  FOR EACH ROW EXECUTE FUNCTION rent_payments_sync_entity_id();

-- 6. Apply standard entity_isolation policy (same form as V5)
DROP POLICY IF EXISTS entity_isolation ON rent_payments;

CREATE POLICY entity_isolation ON rent_payments
  USING (CASE
    WHEN current_setting('app.current_entity', true) = 'all' THEN TRUE
    WHEN current_setting('app.current_entity', true) ~ '^\d+$' THEN
      entity_id = current_setting('app.current_entity', true)::int
    ELSE FALSE
  END)
  WITH CHECK (CASE
    WHEN current_setting('app.current_entity', true) = 'all' THEN TRUE
    WHEN current_setting('app.current_entity', true) ~ '^\d+$' THEN
      entity_id = current_setting('app.current_entity', true)::int
    ELSE FALSE
  END);

-- Verification
SELECT 'rent_payments entity_id column: ' ||
       CASE WHEN EXISTS (
         SELECT 1 FROM information_schema.columns
          WHERE table_name = 'rent_payments' AND column_name = 'entity_id'
       ) THEN 'present' ELSE 'MISSING' END;

SELECT 'rent_payments entity_isolation policy: ' ||
       CASE WHEN EXISTS (
         SELECT 1 FROM pg_policies
          WHERE tablename = 'rent_payments' AND policyname = 'entity_isolation'
       ) THEN 'present' ELSE 'MISSING' END;
```

## Application

Standard pattern — apply when ready:

```bash
docker exec -i homeai-postgres psql -U postgres -d homeai \
  -f - < postgres/migrations/V7__rent_payments_entity_id.sql
```

## Test cases

Once applied, smoke-test the policy with:

```sql
SET ROLE homeai_pipeline;
SET LOCAL app.current_entity = 'all';
SELECT count(*) FROM rent_payments;          -- expect: all rows visible

SET LOCAL app.current_entity = '2';           -- Estates only
SELECT count(*) FROM rent_payments;          -- expect: only entity 2 rows

SET LOCAL app.current_entity = '1';           -- Trading (no rent payments)
SELECT count(*) FROM rent_payments;          -- expect: 0 rows

RESET app.current_entity;                     -- unset
SELECT count(*) FROM rent_payments;          -- expect: 0 (deny-all)
RESET ROLE;
```

## When to apply

Before Phase 2 Step 14 (Bank Reconciliation Pipeline) starts using
`rent_payments`. Currently the table is empty and unused, so this is
zero-risk to apply now. Recommend applying alongside the next batch of
migrations.

## Out of scope

- Backfill validation if rent_payments ever gets data before V7 runs (the
  backfill UPDATE handles all-NULL → all-populated, but if anything has
  partial data with mismatched entity_id, manual reconciliation needed)
- Cross-entity transfer scenarios (e.g., a property internally moves from
  Trading → Estates). Trigger handles the tenancy-level change, but
  historical rent_payments are *not* re-keyed retroactively. That's the
  correct behaviour for audit purposes — past payments belong to the
  entity that received them at the time.
