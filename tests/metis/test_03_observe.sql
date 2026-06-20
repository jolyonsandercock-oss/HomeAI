-- tests/metis/test_03_observe.sql — asserts the metrics SQL the script will run.
\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE m jsonb;
BEGIN
  SELECT jsonb_build_object(
    'population', count(*) FILTER (WHERE is_statement=false AND status NOT IN ('duplicate','ignored')),
    'uncategorised', count(*) FILTER (WHERE category_canonical IS NULL AND is_statement=false AND status NOT IN ('duplicate','ignored'))
  ) INTO m FROM vendor_invoice_inbox;
  ASSERT (m->>'population')::int >= (m->>'uncategorised')::int, 'population must be >= uncategorised';
END $$;
ROLLBACK;
