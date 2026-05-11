-- V7__rent_payments_entity_id.sql
-- Adds entity_id to rent_payments (denormalised from properties.entity_id)
-- and applies the standard entity_isolation RLS policy.
--
-- Why: rent_payments inherits entity scope through a two-hop chain:
--   rent_payments.tenancy_id → tenancies.property_id → properties.entity_id
-- Adding the column directly enables the same simple policy used by every
-- other entity-scoped table. Trigger maintains consistency if a tenancy or
-- property ever changes entity (rare).
--
-- Design rationale: postgres/.claude/decisions/2026-05-08-rent-payments-rls.md
-- Idempotent: safe to re-run.

\set ON_ERROR_STOP on

-- 1. Add column (nullable initially, backfilled, then made NOT NULL)
ALTER TABLE rent_payments
  ADD COLUMN IF NOT EXISTS entity_id INT REFERENCES entities(id);

-- 2. Backfill via tenancies → properties (no-op when table is empty)
UPDATE rent_payments rp
   SET entity_id = p.entity_id
  FROM tenancies t
  JOIN properties p ON p.id = t.property_id
 WHERE t.id = rp.tenancy_id
   AND rp.entity_id IS NULL;

-- 3. Enforce NOT NULL — fails loudly if any row couldn't be backfilled,
--    which would indicate orphan tenancy_id (data integrity issue).
ALTER TABLE rent_payments
  ALTER COLUMN entity_id SET NOT NULL;

-- 4. Index for the policy + entity-scoped queries
CREATE INDEX IF NOT EXISTS idx_rent_payments_entity
  ON rent_payments (entity_id);

-- 5. Trigger to auto-populate entity_id on INSERT/UPDATE.
--    Defence-in-depth: app code may forget to set entity_id; the trigger
--    pulls it from tenancies. If tenancy_id changes mid-update, entity_id
--    re-syncs.
CREATE OR REPLACE FUNCTION rent_payments_sync_entity_id()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.entity_id IS NULL OR
     (TG_OP = 'UPDATE' AND NEW.tenancy_id IS DISTINCT FROM OLD.tenancy_id) THEN
    SELECT p.entity_id INTO NEW.entity_id
      FROM tenancies t
      JOIN properties p ON p.id = t.property_id
     WHERE t.id = NEW.tenancy_id;
    IF NEW.entity_id IS NULL THEN
      RAISE EXCEPTION 'tenancy_id % has no parent property/entity', NEW.tenancy_id;
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

SELECT 'rent_payments_entity_sync trigger: ' ||
       CASE WHEN EXISTS (
         SELECT 1 FROM pg_trigger WHERE tgname = 'rent_payments_entity_sync'
       ) THEN 'present' ELSE 'MISSING' END;
