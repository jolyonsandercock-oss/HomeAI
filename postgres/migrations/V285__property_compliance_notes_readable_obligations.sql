-- V285: property_compliance gets a notes column (insurer/broker details live with
-- the row); v_obligations compliance branch becomes human-readable.
--
-- Context: actioning bot_instructions #1096/#1105 (Reg Hambly insurance-review
-- email 2026-06-23) surfaced that the compliance branch labelled reminders with
-- the raw property_id ("3 insurance" — meaningless in a Telegram nudge or the
-- daily email), hardcoded realm 'work' (Castle Rd/Salutations/Olde Malthouse are
-- personal), and had nowhere to record who the insurer is.
--
-- Only the 'compliance' branch of v_obligations changes; other branches are
-- reproduced verbatim.

ALTER TABLE property_compliance ADD COLUMN IF NOT EXISTS notes text;

CREATE OR REPLACE VIEW v_obligations AS
 SELECT 'mortgage'::text AS source,
    ('mortgage:'::text || mortgage_accounts.id::text) AS source_ref,
    ((mortgage_accounts.lender || ' '::text) || mortgage_accounts.account_ref) AS label,
        CASE
            WHEN (EXTRACT(day FROM CURRENT_DATE))::integer <= mortgage_accounts.payment_day_of_month
            THEN (date_trunc('month'::text, CURRENT_DATE::timestamp with time zone) + ((mortgage_accounts.payment_day_of_month - 1)::double precision * '1 day'::interval))::date
            ELSE (date_trunc('month'::text, CURRENT_DATE + '1 mon'::interval) + ((mortgage_accounts.payment_day_of_month - 1)::double precision * '1 day'::interval))::date
        END AS due_date,
    'mortgage payment'::text AS kind,
    ('£'::text || mortgage_accounts.monthly_payment::text) AS notes,
    'work'::text AS realm
   FROM mortgage_accounts
  WHERE mortgage_accounts.closed_date IS NULL AND mortgage_accounts.monthly_payment IS NOT NULL AND mortgage_accounts.payment_day_of_month IS NOT NULL
UNION ALL
 SELECT 'vehicle'::text, ('vehicle:'::text || vehicles.id::text) || ':mot'::text,
    vehicles.registration || ' MOT'::text, vehicles.mot_due,
    'vehicle MOT'::text, vehicles.make_model, vehicles.realm
   FROM vehicles WHERE vehicles.mot_due IS NOT NULL
UNION ALL
 SELECT 'vehicle'::text, ('vehicle:'::text || vehicles.id::text) || ':insurance'::text,
    vehicles.registration || ' insurance'::text, vehicles.insurance_renewal,
    'vehicle insurance'::text, vehicles.make_model, vehicles.realm
   FROM vehicles WHERE vehicles.insurance_renewal IS NOT NULL
UNION ALL
 SELECT 'vehicle'::text, ('vehicle:'::text || vehicles.id::text) || ':tax'::text,
    vehicles.registration || ' road tax'::text, vehicles.road_tax_due,
    'vehicle road tax'::text, vehicles.make_model, vehicles.realm
   FROM vehicles WHERE vehicles.road_tax_due IS NOT NULL
UNION ALL
 SELECT 'vehicle'::text, ('vehicle:'::text || vehicles.id::text) || ':service'::text,
    vehicles.registration || ' service'::text, vehicles.service_due_date,
    'vehicle service'::text, vehicles.make_model, vehicles.realm
   FROM vehicles WHERE vehicles.service_due_date IS NOT NULL
UNION ALL
 SELECT 'compliance'::text,
    ('compliance:'::text || pc.id::text),
    (COALESCE(p.address_line1, pc.property_id::text) || ' — '::text || pc.compliance_type),
    pc.expiry_date,
    'compliance expiry'::text,
    COALESCE(pc.notes, pc.compliance_type),
    pc.realm
   FROM property_compliance pc
     LEFT JOIN properties p ON p.id = pc.property_id
  WHERE pc.expiry_date IS NOT NULL
UNION ALL
 SELECT 'child'::text, ('child:'::text || child_events.id::text),
    COALESCE(child_events.summary, child_events.event_type),
    COALESCE(child_events.deadline, child_events.event_date),
    'child event'::text, COALESCE(child_events.summary, ''::text), child_events.realm
   FROM child_events
  WHERE COALESCE(child_events.deadline, child_events.event_date) IS NOT NULL
    AND child_events.status <> ALL (ARRAY['done'::text, 'cancelled'::text, 'dismissed'::text]);
