-- =============================================================================
-- V164 — U139: Widen realm vocabulary to include 'personal' (non-breaking).
-- =============================================================================
-- See `.claude/decisions/2026-05-19-realm-personal-pivot.md` for rationale.
--
-- This migration is the WIDENING half of the FAMILY → PERSONAL rename:
--   1. add 'personal' to every realm-aware CHECK constraint
--   2. UPDATE every existing realm='family' row to realm='personal'
--      (requires app.realm_override_active = '1' to bypass immutability)
--   3. add 'personal' WHEN branch to every realm-aware RLS policy
--   4. update home_ai.set_realm() to accept 'personal' and alias 'family'
--   5. update home_ai.realm_override() to accept 'personal' as target
--   6. post-flight assertions
--
-- Non-breaking: services still calling set_realm('family') continue to
-- work via the alias. The 'family' value remains in CHECK constraints
-- and policy CASEs so existing INSERTs and current_setting calls work.
--
-- A later V165 NARROWING migration drops 'family' from vocabulary after
-- services have been updated to use 'personal'.
--
-- Transactional. Aborts cleanly on any error.
-- =============================================================================

BEGIN;

-- Bypass realm-immutability triggers for the data move below.
SELECT set_config('app.realm_override_active', '1', true);
SELECT set_config('app.current_realm', 'owner', true);

-- ---------------------------------------------------------------------------
-- 1. CHECK constraints: insert 'personal'::text into the realm ARRAY first,
--    so subsequent UPDATEs of realm='family'→'personal' satisfy the check.
-- ---------------------------------------------------------------------------
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
           AND cls.relkind = 'r'
           AND NOT EXISTS (
             SELECT 1 FROM pg_inherits i WHERE i.inhrelid = c.conrelid
           )
    LOOP
        old_def := r.def;
        new_def := REPLACE(old_def,
                           '''family''::text,',
                           '''family''::text, ''personal''::text,');
        new_def := REGEXP_REPLACE(new_def, '^CHECK ', '');
        IF new_def = old_def OR new_def = REGEXP_REPLACE(old_def, '^CHECK ', '') THEN
            RAISE NOTICE 'V164: CHECK skipped (no replacement) on %.%: %',
                         r.qtable, r.conname, old_def;
            CONTINUE;
        END IF;
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.qtable, r.conname);
        EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I CHECK %s', r.qtable, r.conname, new_def);
        touched := touched + 1;
    END LOOP;
    RAISE NOTICE 'V164: regenerated % CHECK constraints', touched;
END
$$;

-- ---------------------------------------------------------------------------
-- 2. Data: move every realm='family' row to realm='personal'.
--    The realm_override_active flag set above bypasses the immutability
--    triggers on emails/documents/events/etc.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    r RECORD;
    moved INT;
    total INT := 0;
BEGIN
    FOR r IN
        SELECT n.nspname AS schema, cls.relname AS tbl
          FROM pg_attribute a
          JOIN pg_class cls ON cls.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = cls.relnamespace
         WHERE a.attname = 'realm'
           AND a.attnum > 0
           AND NOT a.attisdropped
           AND cls.relkind = 'r'
           AND n.nspname IN ('public','home_ai')
         ORDER BY n.nspname, cls.relname
    LOOP
        BEGIN
            EXECUTE format('UPDATE %I.%I SET realm = ''personal'' WHERE realm = ''family''',
                           r.schema, r.tbl);
            GET DIAGNOSTICS moved = ROW_COUNT;
            total := total + moved;
            IF moved > 0 THEN
                RAISE NOTICE 'V164: moved % rows in %.%', moved, r.schema, r.tbl;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'V164: skipped %.% (%)', r.schema, r.tbl, SQLERRM;
        END;
    END LOOP;
    RAISE NOTICE 'V164: total family→personal row moves: %', total;
END
$$;

-- ---------------------------------------------------------------------------
-- 3. RLS policies: add 'personal' branch.
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
        SELECT p.oid, p.polname,
               p.polrelid::regclass::text AS qtable,
               p.polrelid,
               pg_get_expr(p.polqual, p.polrelid) AS expr,
               pg_get_expr(p.polwithcheck, p.polrelid) AS chk,
               p.polcmd,
               p.polpermissive
          FROM pg_policy p
          JOIN pg_class cls ON cls.oid = p.polrelid
          JOIN pg_namespace n ON n.oid = cls.relnamespace
         WHERE (pg_get_expr(p.polqual, p.polrelid)      ~ '''family'''
             OR pg_get_expr(p.polwithcheck, p.polrelid) ~ '''family''')
           AND n.nspname IN ('public','home_ai')
    LOOP
        old_expr := r.expr;
        old_chk  := r.chk;

        IF old_expr ~ 'app.current_realm.{0,30}= ''family''::text' THEN
            new_expr := REPLACE(old_expr,
                'ARRAY[''family''::text, ''shared''::text]',
                'ARRAY[''family''::text, ''personal''::text, ''shared''::text]');
            new_expr := REGEXP_REPLACE(new_expr,
                E'(WHEN \\(current_setting\\(''app\\.current_realm''::text, true\\) = ''family''::text\\) THEN \\(realm = ANY \\(ARRAY\\[''family''::text, ''personal''::text, ''shared''::text\\]\\)\\))',
                E'\\1\n    WHEN (current_setting(''app.current_realm''::text, true) = ''personal''::text) THEN (realm = ANY (ARRAY[''family''::text, ''personal''::text, ''shared''::text]))',
                'g');
        ELSIF old_expr ~ 'ANY \(ARRAY\[''work''::text, ''family''::text\]\)' THEN
            new_expr := REPLACE(old_expr,
                'ARRAY[''work''::text, ''family''::text]',
                'ARRAY[''work''::text, ''family''::text, ''personal''::text]');
        ELSE
            new_expr := old_expr;
        END IF;

        IF old_chk IS NOT NULL THEN
            IF old_chk ~ 'app.current_realm.{0,30}= ''family''::text' THEN
                new_chk := REPLACE(old_chk,
                    'ARRAY[''family''::text, ''shared''::text]',
                    'ARRAY[''family''::text, ''personal''::text, ''shared''::text]');
                new_chk := REGEXP_REPLACE(new_chk,
                    E'(WHEN \\(current_setting\\(''app\\.current_realm''::text, true\\) = ''family''::text\\) THEN \\(realm = ANY \\(ARRAY\\[''family''::text, ''personal''::text, ''shared''::text\\]\\)\\))',
                    E'\\1\n    WHEN (current_setting(''app.current_realm''::text, true) = ''personal''::text) THEN (realm = ANY (ARRAY[''family''::text, ''personal''::text, ''shared''::text]))',
                    'g');
            ELSIF old_chk ~ 'ANY \(ARRAY\[''work''::text, ''family''::text\]\)' THEN
                new_chk := REPLACE(old_chk,
                    'ARRAY[''work''::text, ''family''::text]',
                    'ARRAY[''work''::text, ''family''::text, ''personal''::text]');
            ELSE
                new_chk := old_chk;
            END IF;
        ELSE
            new_chk := NULL;
        END IF;

        IF new_expr = old_expr AND (new_chk IS NULL OR new_chk = old_chk) THEN
            RAISE NOTICE 'V164: policy unchanged on %.%, expr: %',
                         r.qtable, r.polname, LEFT(old_expr, 80);
            CONTINUE;
        END IF;

        polcmd_str := CASE r.polcmd
                        WHEN 'r' THEN 'FOR SELECT'
                        WHEN 'a' THEN 'FOR INSERT'
                        WHEN 'w' THEN 'FOR UPDATE'
                        WHEN 'd' THEN 'FOR DELETE'
                        WHEN '*' THEN ''
                      END;
        perm_str   := CASE WHEN r.polpermissive THEN '' ELSE 'AS RESTRICTIVE' END;
        using_clause := 'USING (' || new_expr || ')';
        check_clause := CASE WHEN new_chk IS NOT NULL THEN ' WITH CHECK (' || new_chk || ')' ELSE '' END;

        EXECUTE format('DROP POLICY %I ON %s', r.polname, r.qtable);
        EXECUTE format('CREATE POLICY %I ON %s %s %s %s%s',
                       r.polname, r.qtable, perm_str, polcmd_str, using_clause, check_clause);
        touched := touched + 1;
    END LOOP;
    RAISE NOTICE 'V164: regenerated % RLS policies', touched;
END
$$;

-- ---------------------------------------------------------------------------
-- 4. home_ai.set_realm — accept 'personal'; alias deprecated 'family'.
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

    IF p_realm NOT IN ('owner','work','personal','family') THEN
        RAISE EXCEPTION 'home_ai.set_realm: invalid realm %, expected one of (owner, work, personal)', p_realm
            USING ERRCODE = '22023';
    END IF;

    -- V164 transitional: 'family' is deprecated, aliased to 'personal'.
    IF p_realm = 'family' THEN
        p_realm := 'personal';
    END IF;

    PERFORM set_config('app.current_realm', p_realm, true);
    RETURN p_realm;
END
$function$;

-- ---------------------------------------------------------------------------
-- 5. home_ai.realm_override — accept 'personal' as a valid target.
--    (Required for any future OWNER-driven realm change to 'personal'.)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    body TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
      FROM pg_proc
     WHERE proname = 'realm_override'
       AND pronamespace = 'home_ai'::regnamespace;

    IF body IS NULL THEN
        RAISE NOTICE 'V164: home_ai.realm_override not found, skipping';
        RETURN;
    END IF;

    -- Replace the validation list to include 'personal'
    body := REPLACE(body,
                    'p_new_realm NOT IN (''owner'',''work'',''family'',''shared'')',
                    'p_new_realm NOT IN (''owner'',''work'',''personal'',''family'',''shared'')');
    -- Strip leading "CREATE OR REPLACE FUNCTION " so EXECUTE works
    EXECUTE body;
END
$$;

-- ---------------------------------------------------------------------------
-- 6. Post-flight assertions.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    fam_rows INT;
BEGIN
    SELECT COALESCE(SUM(c), 0) INTO fam_rows FROM (
        SELECT COUNT(*) c FROM entities    WHERE realm='family'
        UNION ALL SELECT COUNT(*) FROM documents  WHERE realm='family'
        UNION ALL SELECT COUNT(*) FROM properties WHERE realm='family'
        UNION ALL SELECT COUNT(*) FROM children   WHERE realm='family'
    ) s;
    IF fam_rows > 0 THEN
        RAISE EXCEPTION 'V164 post-flight: % rows still tagged realm=family after UPDATE pass', fam_rows;
    END IF;
END
$$;

COMMIT;
