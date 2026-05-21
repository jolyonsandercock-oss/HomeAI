-- =============================================================================
-- V178 — U146 T4: widen realm CHECK on partition parents in mart/raw/staging
-- =============================================================================
-- V164 widened public.* and home_ai.* partition parents (where the main loop
-- worked) and V164b widened public/home_ai partitioned-parent tables. Neither
-- covered mart/raw/staging schemas, which contain 11 partitioned parents
-- holding 349 child partitions. Result: those 349 children still reject
-- realm='personal'.
--
-- Fix: ALTER the 11 parents (relkind='p'). PostgreSQL cascades the new
-- CHECK to all children automatically (a partition child cannot deviate
-- from its parent's CHECK on the partition key, but for non-partition-key
-- columns the cascade IS automatic on declarative partitioning).
--
-- Idempotent. Aborts cleanly on any error.
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
               n.nspname || '.' || cls.relname AS qtable,
               pg_get_constraintdef(c.oid) AS def
          FROM pg_constraint c
          JOIN pg_class cls ON cls.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = cls.relnamespace
         WHERE c.contype = 'c'
           AND pg_get_constraintdef(c.oid) ~ '''family'''
           AND pg_get_constraintdef(c.oid) !~ '''personal'''
           AND n.nspname IN ('mart','raw','staging')
           AND cls.relkind = 'p'
    LOOP
        old_def := r.def;
        new_def := REPLACE(old_def,
                           '''family''::text',
                           '''family''::text, ''personal''::text');
        new_def := REGEXP_REPLACE(new_def, '^CHECK ', '');

        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I',
                       r.qtable, r.conname);
        EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s',
                       r.qtable, r.conname, 'CHECK ' || new_def);
        touched := touched + 1;
        RAISE NOTICE 'V178: widened %.%', r.qtable, r.conname;
    END LOOP;

    RAISE NOTICE 'V178: widened % partition-parent CHECK constraints (mart/raw/staging)', touched;
END $$;

-- Post-flight: zero family-only CHECK constraints anywhere now.
DO $$
DECLARE
    remaining INT;
BEGIN
    SELECT count(*) INTO remaining
      FROM pg_constraint c
     WHERE c.conname LIKE '%realm_check%'
       AND pg_get_constraintdef(c.oid) ~ '''family'''
       AND pg_get_constraintdef(c.oid) !~ '''personal''';

    IF remaining > 0 THEN
        RAISE EXCEPTION 'V178 post-flight: % family-only CHECK constraints still present', remaining;
    END IF;
    RAISE NOTICE 'V178 post-flight: ok — every realm CHECK now allows personal';
END $$;

COMMIT;
