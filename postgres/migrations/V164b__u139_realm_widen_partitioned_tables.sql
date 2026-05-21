-- =============================================================================
-- V164b — U139 follow-up: widen CHECK constraints on partitioned tables.
-- =============================================================================
-- V164's main loop skipped any table where pg_inherits.inhrelid pointed to it
-- (to avoid double-altering inherited constraints on child partitions).
-- That also accidentally skipped the partition PARENT tables themselves.
-- For PARTITIONED tables (relkind='p') the constraint lives on the parent;
-- ALTER on the parent cascades to all children atomically.
--
-- This migration widens those parent constraints. The 252 child partitions
-- inherit the fix automatically.
-- =============================================================================

BEGIN;

DO $$
DECLARE
    r RECORD;
    old_def TEXT;
    new_def TEXT;
    touched INT := 0;
BEGIN
    FOR r IN
        SELECT c.oid, c.conname,
               c.conrelid::regclass::text AS qtable,
               pg_get_constraintdef(c.oid) AS def
          FROM pg_constraint c
          JOIN pg_class cls ON cls.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = cls.relnamespace
         WHERE c.contype = 'c'
           AND pg_get_constraintdef(c.oid) ~ '''family'''
           AND pg_get_constraintdef(c.oid) !~ '''personal'''
           AND n.nspname IN ('public','home_ai')
           AND cls.relkind = 'p'           -- partitioned tables only
    LOOP
        old_def := r.def;
        new_def := REPLACE(old_def,
                           '''family''::text,',
                           '''family''::text, ''personal''::text,');
        new_def := REGEXP_REPLACE(new_def, '^CHECK ', '');
        IF new_def = old_def OR new_def = REGEXP_REPLACE(old_def, '^CHECK ', '') THEN
            RAISE NOTICE 'V164b: CHECK skipped (no replacement) on %.%: %',
                         r.qtable, r.conname, old_def;
            CONTINUE;
        END IF;
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.qtable, r.conname);
        EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I CHECK %s', r.qtable, r.conname, new_def);
        touched := touched + 1;
        RAISE NOTICE 'V164b: widened % on %', r.conname, r.qtable;
    END LOOP;
    RAISE NOTICE 'V164b: regenerated % partitioned-table CHECK constraints', touched;
END
$$;

-- Sanity: any remaining 'family'-only check constraints?
DO $$
DECLARE leftover INT;
BEGIN
    SELECT COUNT(*) INTO leftover
      FROM pg_constraint c
      JOIN pg_class cls ON cls.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = cls.relnamespace
     WHERE c.contype = 'c'
       AND pg_get_constraintdef(c.oid) ~ '''family'''
       AND pg_get_constraintdef(c.oid) !~ '''personal'''
       AND n.nspname IN ('public','home_ai');
    IF leftover > 0 THEN
        RAISE NOTICE 'V164b: % CHECK constraints still on family-only (likely child partitions inheriting from a parent now widened)', leftover;
    END IF;
END
$$;

COMMIT;
