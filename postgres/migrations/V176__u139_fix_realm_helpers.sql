-- =============================================================================
-- V176 — U139: fix realm-emitting helper functions to return 'personal'
-- instead of 'family'. Without this, the events.realm BEFORE-INSERT trigger
-- keeps writing 'family' rows even after V164 widened the vocabulary.
--
-- Also re-runs the family→personal data move on every realm-tagged table
-- (V164 ran once at apply time; this catches anything written since).
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.realm_from_entity_id(p_entity_id integer)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    RETURN CASE
        WHEN p_entity_id = 1            THEN 'work'
        WHEN p_entity_id IN (2,3,4)     THEN 'personal'
        ELSE 'owner'
    END;
END
$$;

CREATE OR REPLACE FUNCTION public.realm_from_account(p_account text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    RETURN CASE
        WHEN p_account IN ('info','admin')  THEN 'work'
        WHEN p_account IN ('jo','pounana')  THEN 'personal'
        WHEN p_account = 'bot'              THEN 'owner'
        ELSE 'owner'
    END;
END
$$;

-- Re-migrate any rows that have been written as 'family' since V164.
-- realm_override_active bypasses the immutability trigger.
SELECT set_config('app.realm_override_active', '1', true);
SELECT set_config('app.current_realm', 'owner', true);

DO $$
DECLARE
    r RECORD;
    moved INT;
    total INT := 0;
BEGIN
    FOR r IN
        SELECT n.nspname AS sch, cls.relname AS t
          FROM pg_attribute a
          JOIN pg_class cls ON cls.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = cls.relnamespace
         WHERE a.attname='realm' AND cls.relkind='r'
           AND n.nspname IN ('public','home_ai')
    LOOP
        BEGIN
            EXECUTE format('UPDATE %I.%I SET realm = ''personal'' WHERE realm = ''family''',
                           r.sch, r.t);
            GET DIAGNOSTICS moved = ROW_COUNT;
            total := total + moved;
            IF moved > 0 THEN
                RAISE NOTICE 'V176: moved % rows in %.%', moved, r.sch, r.t;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'V176: skipped %.% (%)', r.sch, r.t, SQLERRM;
        END;
    END LOOP;
    RAISE NOTICE 'V176: total moves: %', total;
END
$$;

COMMIT;
