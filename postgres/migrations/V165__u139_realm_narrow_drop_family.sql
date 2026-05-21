-- =============================================================================
-- V165 — U139: Narrow realm vocabulary — drop 'family' (companion to V164).
-- =============================================================================
-- WARNING: DO NOT APPLY until services are confirmed not to write 'family'.
--
-- V164 widened the vocabulary to accept both 'family' and 'personal'. This
-- migration narrows it: 'family' is no longer a valid realm anywhere.
--
-- Prerequisites:
--   1. Every service container that writes realm values has been rebuilt
--      with the V164 service-side updates (commits 2026-05-19+).
--   2. 24h of observation showing no logged set_realm('family') call and
--      no INSERTs with realm='family' attempted.
--   3. realm='family' row count is 0 across all tables (V164 already moved
--      them; this is just a re-check before narrowing).
--
-- Operation:
--   * Remove 'family'::text from every realm CHECK constraint ARRAY.
--   * Remove 'family' WHEN branch from every RLS policy.
--   * home_ai.set_realm() rejects 'family' (no more alias).
--   * home_ai.realm_override() removes 'family' from valid targets.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0. Pre-flight: no family rows allowed.
-- ---------------------------------------------------------------------------
DO $$
DECLARE leftover INT := 0; tbl RECORD; n INT;
BEGIN
    FOR tbl IN
        SELECT n.nspname AS schema, cls.relname AS t
          FROM pg_attribute a
          JOIN pg_class cls ON cls.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = cls.relnamespace
         WHERE a.attname='realm' AND cls.relkind='r' AND n.nspname IN ('public','home_ai')
    LOOP
        EXECUTE format('SELECT COUNT(*) FROM %I.%I WHERE realm=''family''', tbl.schema, tbl.t) INTO n;
        leftover := leftover + COALESCE(n, 0);
    END LOOP;
    IF leftover > 0 THEN
        RAISE EXCEPTION 'V165 pre-flight: % rows still realm=family — V164 alias was bypassed somewhere. Investigate before narrowing.', leftover;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 1. CHECK constraints: remove 'family'::text from the ARRAY.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    r RECORD;
    old_def TEXT;
    new_def TEXT;
    touched INT := 0;
BEGIN
    FOR r IN
        SELECT c.oid, c.conname, c.conrelid::regclass::text AS qtable,
               pg_get_constraintdef(c.oid) AS def
          FROM pg_constraint c
          JOIN pg_class cls ON cls.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = cls.relnamespace
         WHERE c.contype = 'c'
           AND pg_get_constraintdef(c.oid) ~ '''family'''
           AND n.nspname IN ('public','home_ai')
           AND cls.relkind IN ('r','p')
           AND (cls.relkind = 'p' OR NOT EXISTS (
                 SELECT 1 FROM pg_inherits i WHERE i.inhrelid = c.conrelid
           ))
    LOOP
        old_def := r.def;
        -- Drop the ''family''::text, fragment whether or not 'personal' is around it
        new_def := REPLACE(old_def, '''family''::text, ', '');
        new_def := REPLACE(new_def, ', ''family''::text', '');
        new_def := REGEXP_REPLACE(new_def, '^CHECK ', '');
        IF new_def = REGEXP_REPLACE(old_def, '^CHECK ', '') THEN
            CONTINUE;
        END IF;
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.qtable, r.conname);
        EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I CHECK %s', r.qtable, r.conname, new_def);
        touched := touched + 1;
    END LOOP;
    RAISE NOTICE 'V165: narrowed % CHECK constraints', touched;
END $$;

-- ---------------------------------------------------------------------------
-- 2. RLS policies: drop 'family' WHEN branch.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    r RECORD;
    old_expr TEXT;
    new_expr TEXT;
    old_chk TEXT;
    new_chk TEXT;
    polcmd_str TEXT;
    perm_str TEXT;
    using_clause TEXT;
    check_clause TEXT;
    touched INT := 0;
BEGIN
    FOR r IN
        SELECT p.oid, p.polname, p.polrelid::regclass::text AS qtable,
               pg_get_expr(p.polqual, p.polrelid) AS expr,
               pg_get_expr(p.polwithcheck, p.polrelid) AS chk,
               p.polcmd, p.polpermissive
          FROM pg_policy p
          JOIN pg_class cls ON cls.oid = p.polrelid
          JOIN pg_namespace n ON n.oid = cls.relnamespace
         WHERE (pg_get_expr(p.polqual, p.polrelid)      ~ '''family'''
             OR pg_get_expr(p.polwithcheck, p.polrelid) ~ '''family''')
           AND n.nspname IN ('public','home_ai')
    LOOP
        old_expr := r.expr;
        old_chk  := r.chk;

        -- Strip the 'family' WHEN branch line entirely (Shape A)
        new_expr := REGEXP_REPLACE(old_expr,
            E'\\s*WHEN \\(current_setting\\(''app\\.current_realm''::text, true\\) = ''family''::text\\) THEN \\(realm = ANY \\(ARRAY\\[''family''::text, ''personal''::text, ''shared''::text\\]\\)\\)',
            '', 'g');
        -- Drop 'family'::text from any remaining ARRAYs (e.g. personal branch's array)
        new_expr := REPLACE(new_expr, '''family''::text, ''personal''::text, ''shared''::text',
                                       '''personal''::text, ''shared''::text');
        -- Shape B: ANY(ARRAY['work','family','personal']) → drop family
        new_expr := REPLACE(new_expr,
            'ARRAY[''work''::text, ''family''::text, ''personal''::text]',
            'ARRAY[''work''::text, ''personal''::text]');

        IF old_chk IS NOT NULL THEN
            new_chk := REGEXP_REPLACE(old_chk,
                E'\\s*WHEN \\(current_setting\\(''app\\.current_realm''::text, true\\) = ''family''::text\\) THEN \\(realm = ANY \\(ARRAY\\[''family''::text, ''personal''::text, ''shared''::text\\]\\)\\)',
                '', 'g');
            new_chk := REPLACE(new_chk, '''family''::text, ''personal''::text, ''shared''::text',
                                         '''personal''::text, ''shared''::text');
            new_chk := REPLACE(new_chk,
                'ARRAY[''work''::text, ''family''::text, ''personal''::text]',
                'ARRAY[''work''::text, ''personal''::text]');
        ELSE
            new_chk := NULL;
        END IF;

        IF new_expr = old_expr AND (new_chk IS NULL OR new_chk = old_chk) THEN
            CONTINUE;
        END IF;

        polcmd_str := CASE r.polcmd
                        WHEN 'r' THEN 'FOR SELECT'
                        WHEN 'a' THEN 'FOR INSERT'
                        WHEN 'w' THEN 'FOR UPDATE'
                        WHEN 'd' THEN 'FOR DELETE'
                        WHEN '*' THEN ''
                      END;
        perm_str := CASE WHEN r.polpermissive THEN '' ELSE 'AS RESTRICTIVE' END;
        using_clause := 'USING (' || new_expr || ')';
        check_clause := CASE WHEN new_chk IS NOT NULL THEN ' WITH CHECK (' || new_chk || ')' ELSE '' END;

        EXECUTE format('DROP POLICY %I ON %s', r.polname, r.qtable);
        EXECUTE format('CREATE POLICY %I ON %s %s %s %s%s',
                       r.polname, r.qtable, perm_str, polcmd_str, using_clause, check_clause);
        touched := touched + 1;
    END LOOP;
    RAISE NOTICE 'V165: narrowed % RLS policies', touched;
END $$;

-- ---------------------------------------------------------------------------
-- 3. home_ai.set_realm: drop 'family' alias.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION home_ai.set_realm(p_realm text)
RETURNS text
LANGUAGE plpgsql
AS $function$
BEGIN
    IF p_realm IS NULL OR p_realm = '' THEN
        PERFORM set_config('app.current_realm', '', true);
        RETURN '';
    END IF;
    IF p_realm NOT IN ('owner','work','personal') THEN
        RAISE EXCEPTION 'home_ai.set_realm: invalid realm %, expected one of (owner, work, personal)', p_realm
            USING ERRCODE = '22023';
    END IF;
    PERFORM set_config('app.current_realm', p_realm, true);
    RETURN p_realm;
END
$function$;

-- ---------------------------------------------------------------------------
-- 4. home_ai.realm_override: drop 'family' from valid targets.
-- ---------------------------------------------------------------------------
DO $$
DECLARE body TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
      FROM pg_proc
     WHERE proname = 'realm_override' AND pronamespace = 'home_ai'::regnamespace;
    IF body IS NULL THEN RETURN; END IF;
    body := REPLACE(body,
        'p_new_realm NOT IN (''owner'',''work'',''personal'',''family'',''shared'')',
        'p_new_realm NOT IN (''owner'',''work'',''personal'',''shared'')');
    EXECUTE body;
END $$;

-- ---------------------------------------------------------------------------
-- 5. Final assertion: no 'family' references remain in policies/constraints.
-- ---------------------------------------------------------------------------
DO $$
DECLARE n INT;
BEGIN
    SELECT COUNT(*) INTO n
      FROM pg_constraint c
      JOIN pg_class cls ON cls.oid = c.conrelid
      JOIN pg_namespace nsp ON nsp.oid = cls.relnamespace
     WHERE c.contype='c'
       AND pg_get_constraintdef(c.oid) ~ '''family'''
       AND nsp.nspname IN ('public','home_ai');
    IF n > 0 THEN RAISE EXCEPTION 'V165: % CHECK constraints still reference ''family''', n; END IF;

    SELECT COUNT(*) INTO n FROM pg_policy
     WHERE pg_get_expr(polqual, polrelid) ~ '''family'''
        OR pg_get_expr(polwithcheck, polrelid) ~ '''family''';
    IF n > 0 THEN RAISE EXCEPTION 'V165: % policies still reference ''family''', n; END IF;
END $$;

COMMIT;
