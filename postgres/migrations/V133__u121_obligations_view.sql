-- =============================================================================
-- V133 — U121: unified obligations view + reminder log
-- =============================================================================
-- Pulls every dated obligation from across the system into one calendar
-- feed: mortgage payment day, vehicle MOT/insurance/tax/service, property
-- compliance expiry, child events, and any one-off task with a deadline.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

CREATE TABLE IF NOT EXISTS obligation_reminders (
  id              BIGSERIAL PRIMARY KEY,
  source          TEXT NOT NULL,          -- mortgage / vehicle / compliance / child
  source_ref      TEXT NOT NULL,          -- composite key, e.g. "vehicle:42:mot"
  due_date        DATE NOT NULL,
  reminded_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  realm           TEXT NOT NULL DEFAULT 'owner',
  UNIQUE (source, source_ref, due_date)
);
COMMENT ON TABLE obligation_reminders IS
'U121 V133. UNIQUE key dedupes — each (source_ref × due_date) is reminded
exactly once. Reset by deleting the row if a deadline shifts.';

DROP VIEW IF EXISTS v_obligations CASCADE;
CREATE VIEW v_obligations AS
-- Mortgages — monthly DD on the day-of-month implied by opened_date
SELECT
  'mortgage'::text                    AS source,
  ('mortgage:' || id::text)           AS source_ref,
  lender || ' ' || account_ref        AS label,
  (DATE_TRUNC('month', CURRENT_DATE)
   + (EXTRACT(DAY FROM opened_date)::int - 1) * INTERVAL '1 day')::date
   + (CASE WHEN EXTRACT(DAY FROM CURRENT_DATE)::int > EXTRACT(DAY FROM opened_date)::int
           THEN INTERVAL '1 month' ELSE INTERVAL '0' END)::interval AS due_date,
  'mortgage payment'::text            AS kind,
  monthly_payment::text || ' GBP'     AS notes,
  'work'::text                        AS realm
FROM mortgage_accounts
WHERE closed_date IS NULL AND monthly_payment IS NOT NULL
UNION ALL
-- Vehicles — MOT
SELECT 'vehicle', 'vehicle:' || id::text || ':mot',
       registration || ' MOT', mot_due::date, 'vehicle MOT',
       make_model, realm
  FROM vehicles WHERE mot_due IS NOT NULL
UNION ALL
-- Vehicles — insurance
SELECT 'vehicle', 'vehicle:' || id::text || ':insurance',
       registration || ' insurance', insurance_renewal::date, 'vehicle insurance',
       make_model, realm
  FROM vehicles WHERE insurance_renewal IS NOT NULL
UNION ALL
-- Vehicles — road tax
SELECT 'vehicle', 'vehicle:' || id::text || ':tax',
       registration || ' road tax', road_tax_due::date, 'vehicle road tax',
       make_model, realm
  FROM vehicles WHERE road_tax_due IS NOT NULL
UNION ALL
-- Vehicles — service
SELECT 'vehicle', 'vehicle:' || id::text || ':service',
       registration || ' service', service_due_date::date, 'vehicle service',
       make_model, realm
  FROM vehicles WHERE service_due_date IS NOT NULL
UNION ALL
-- Property compliance — expiry
SELECT 'compliance', 'compliance:' || id::text,
       property_id::text || ' ' || compliance_type, expiry_date,
       'compliance expiry',
       compliance_type, 'work'
  FROM property_compliance WHERE expiry_date IS NOT NULL
UNION ALL
-- Children events with a deadline
SELECT 'child', 'child:' || id::text,
       COALESCE(summary, event_type), COALESCE(deadline::date, event_date::date),
       'child event', COALESCE(summary, ''), realm
  FROM child_events
 WHERE COALESCE(deadline, event_date) IS NOT NULL
   AND status NOT IN ('done','cancelled','dismissed');

COMMENT ON VIEW v_obligations IS
'U121 V133. All dated obligations unioned. Filter due_date as needed.';

DROP VIEW IF EXISTS v_obligations_due_3d CASCADE;
CREATE VIEW v_obligations_due_3d AS
SELECT * FROM v_obligations
 WHERE due_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 3
 ORDER BY due_date, source, label;

COMMENT ON VIEW v_obligations_due_3d IS
'U121 V133. Things due in the next 3 days — input for the daily reminder cron.';

INSERT INTO query_whitelist (slug, display_name, sql_template, description,
                              created_by, realm, entity_id, intent_examples,
                              approved_at, approved_by)
VALUES
  ('obligations_upcoming',
   'U121 — obligations next 30 days',
   'SELECT due_date, source, label, kind, notes FROM v_obligations WHERE due_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 30 ORDER BY due_date',
   'All dated obligations in the next 30 days',
   'u121','owner',1, ARRAY['obligations','upcoming bills','deadlines'],
   now(),'u121'),
  ('obligations_due_3d',
   'U121 — obligations due ≤ 3 days',
   'SELECT * FROM v_obligations_due_3d',
   'Anything due in the next 3 days — daily reminder feed',
   'u121','owner',1, ARRAY['due soon','3 days','reminders'],
   now(),'u121')
ON CONFLICT (slug) DO UPDATE SET sql_template=EXCLUDED.sql_template, approved_at=now(), approved_by='u121';

COMMIT;
