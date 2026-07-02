-- V281: generic partition maintenance (replaces events-only ensure_next_event_partition)
CREATE OR REPLACE FUNCTION ops.ensure_partitions()
RETURNS TABLE(parent text, partition_name text, was_created boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE p RECORD; m DATE; pname TEXT; existed BOOLEAN;
BEGIN
  FOR p IN SELECT ns.nspname AS sch, c.relname AS tbl
           FROM pg_partitioned_table pt
           JOIN pg_class c ON c.oid = pt.partrelid
           JOIN pg_namespace ns ON ns.oid = c.relnamespace LOOP
    FOR m IN SELECT generate_series(date_trunc('month', now())::date,
                                    date_trunc('month', now() + interval '2 months')::date,
                                    interval '1 month')::date LOOP
      pname := p.tbl || '_' || to_char(m, 'YYYY_MM');
      existed := EXISTS (SELECT 1 FROM pg_class pc JOIN pg_namespace pn ON pn.oid=pc.relnamespace
                         WHERE pc.relname=pname AND pn.nspname=p.sch);
      IF NOT existed THEN
        EXECUTE format('CREATE TABLE %I.%I PARTITION OF %I.%I FOR VALUES FROM (%L) TO (%L)',
                       p.sch, pname, p.sch, p.tbl, m, m + interval '1 month');
      END IF;
      parent := p.sch||'.'||p.tbl; partition_name := pname; was_created := NOT existed; RETURN NEXT;
    END LOOP;
    pname := p.tbl || '_overflow';
    existed := EXISTS (SELECT 1 FROM pg_class pc JOIN pg_namespace pn ON pn.oid=pc.relnamespace
                       WHERE pc.relname=pname AND pn.nspname=p.sch);
    IF NOT existed THEN
      EXECUTE format('CREATE TABLE %I.%I PARTITION OF %I.%I DEFAULT', p.sch, pname, p.sch, p.tbl);
    END IF;
    parent := p.sch||'.'||p.tbl; partition_name := pname; was_created := NOT existed; RETURN NEXT;
  END LOOP;
END $$;
