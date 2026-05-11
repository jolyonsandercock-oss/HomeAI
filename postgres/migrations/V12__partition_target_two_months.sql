-- V12: bump ensure_next_event_partition to target month +2 (was +1).
--
-- SPEC v5.3 Pipeline 11 specifies `now.getMonth() + 2` — i.e. when the cron
-- fires on the 25th, it creates the partition for the month *after* next, not
-- next month. This gives ~36 days of buffer instead of ~6, so a missed cron
-- run (Vault sealed, host down on the 25th, etc.) doesn't immediately push
-- writes to events_overflow.
--
-- The function signature, return columns, and SECURITY DEFINER posture are
-- unchanged — only the date arithmetic shifts.

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
  next_start := date_trunc('month', now() + INTERVAL '2 months')::DATE;
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
