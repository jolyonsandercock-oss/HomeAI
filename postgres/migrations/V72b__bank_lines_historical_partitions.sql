\set ON_ERROR_STOP on
BEGIN;
SELECT set_config('app.current_entity', 'all', false);
SELECT set_config('app.current_realm',  'owner', false);

DO $$
DECLARE
    d DATE := '2019-01-01';
    end_d DATE := '2026-06-01';
    next_d DATE;
    tag TEXT;
    sch TEXT;
    tbl TEXT;
    part_name TEXT;
    parent TEXT;
    created INT := 0;
    parents TEXT[] := ARRAY['raw.bank_lines','staging.bank_lines'];
BEGIN
    WHILE d < end_d LOOP
        next_d := (d + INTERVAL '1 month')::DATE;
        tag := TO_CHAR(d, 'YYYY_MM');
        FOREACH parent IN ARRAY parents LOOP
            sch := split_part(parent, '.', 1);
            tbl := split_part(parent, '.', 2);
            part_name := tbl || '_' || tag;
            IF NOT EXISTS (
                SELECT 1 FROM pg_class c
                  JOIN pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = sch AND c.relname = part_name
            ) THEN
                EXECUTE format(
                    'CREATE TABLE %I.%I PARTITION OF %I.%I FOR VALUES FROM (%L) TO (%L)',
                    sch, part_name, sch, tbl, d, next_d);
                created := created + 1;
            END IF;
        END LOOP;
        d := next_d;
    END LOOP;
    RAISE NOTICE 'created % new partitions across raw.bank_lines and staging.bank_lines.', created;
END $$;

COMMIT;
