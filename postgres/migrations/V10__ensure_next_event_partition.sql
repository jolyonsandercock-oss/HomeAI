-- V10: ensure_next_event_partition() — idempotent helper for Pipeline 11.
--
-- Computes the calendar month *after* the current month, derives the partition
-- name `events_YYYY_MM`, and creates the partition with the matching range
-- bounds if it does not already exist. Returns one row describing the target
-- partition and whether this call created it.
--
-- SECURITY DEFINER so n8n's homeai_pipeline role (no DDL grant) can invoke it.
-- The function body uses EXECUTE format(...) with %I (identifier-quoted name)
-- and %L (literal-quoted timestamp bounds) to avoid SQL injection — although
-- the inputs are derived from now() and not user-supplied, the discipline is
-- worth keeping for any future change that takes a target month parameter.

CREATE OR REPLACE FUNCTION ensure_next_event_partition()
RETURNS TABLE(
  partition_name TEXT,
  range_start    DATE,
  range_end      DATE,
  was_created    BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  next_start DATE;
  next_end   DATE;
  pname      TEXT;
  existed    BOOLEAN;
BEGIN
  next_start := date_trunc('month', now() + INTERVAL '1 month')::DATE;
  next_end   := (next_start + INTERVAL '1 month')::DATE;
  pname      := 'events_' || to_char(next_start, 'YYYY_MM');

  existed := to_regclass('public.' || quote_ident(pname)) IS NOT NULL;

  IF NOT existed THEN
    EXECUTE format(
      'CREATE TABLE %I PARTITION OF events FOR VALUES FROM (%L) TO (%L)',
      pname, next_start, next_end
    );
  END IF;

  partition_name := pname;
  range_start    := next_start;
  range_end      := next_end;
  was_created    := NOT existed;
  RETURN NEXT;
END;
$fn$;

GRANT EXECUTE ON FUNCTION ensure_next_event_partition() TO homeai_pipeline;
