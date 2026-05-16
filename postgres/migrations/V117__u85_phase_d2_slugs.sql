-- =============================================================================
-- V117 — U85 Phase D2: today_bookings + today_pub_sales views + slugs
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

DROP VIEW IF EXISTS v_today_bookings;
CREATE VIEW v_today_bookings AS
SELECT
  id, source, source_ref, guest_name, room,
  checkin_date, checkout_date, gross_amount, payment_status, status, realm
FROM accommodation_bookings
WHERE checkin_date = CURRENT_DATE
  AND status IN ('confirmed','deposit_paid','paid','active')
ORDER BY id;

COMMENT ON VIEW v_today_bookings IS
'U85 §T03. Accommodation bookings checking in today (active statuses only).';

DROP VIEW IF EXISTS v_today_pub_sales;
CREATE VIEW v_today_pub_sales AS
SELECT
  site, department, value::numeric(12,2) AS net_value, quantity
FROM touchoffice_department_sales
WHERE report_date = CURRENT_DATE
ORDER BY value DESC NULLS LAST;

COMMENT ON VIEW v_today_pub_sales IS
'U85 §T04. TouchOffice department sales for today, ordered by value.';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'homeai_pipeline') THEN
    EXECUTE 'GRANT SELECT ON v_today_bookings, v_today_pub_sales TO homeai_pipeline';
  END IF;
END$$;

INSERT INTO query_whitelist (slug, display_name, sql_template, description,
                              created_by, realm, entity_id, intent_examples,
                              approved_at, approved_by)
VALUES
  ('today_bookings','U85 §T03 — Today bookings list',
   'SELECT * FROM v_today_bookings',
   'Accommodation bookings checking in today',
   'u85-phase-d2','owner',1, ARRAY['todays bookings'],
   now(),'u85-phase-d2'),
  ('today_pub_sales','U85 §T04 — Today TouchOffice sales by department',
   'SELECT * FROM v_today_pub_sales',
   'Today sales by department + site from TouchOffice',
   'u85-phase-d2','owner',1, ARRAY['todays pub sales'],
   now(),'u85-phase-d2')
ON CONFLICT (slug) DO UPDATE
  SET sql_template=EXCLUDED.sql_template, approved_at=now(), approved_by='u85-phase-d2';

COMMIT;
