-- V219 — U234: salaried staff (source of truth for salaried labour cost)
--
-- Tanda/workforce rosters salaried staff as shifts with an hourly cost_estimate,
-- which is wrong for a fixed-salary role (and understated overall labour — it
-- read 18.6% because the GM's salary wasn't counted). This table holds salaried
-- roles; labour-cost computations EXCLUDE their workforce_shifts (matched by
-- workforce_external_id) and add their salary pro-rata instead.

CREATE TABLE IF NOT EXISTS salaried_staff (
  id                    serial PRIMARY KEY,
  name                  text NOT NULL,
  workforce_external_id text,                       -- workforce_users.external_id, to exclude hourly shifts
  position_title        text,
  annual_salary         numeric NOT NULL,
  on_cost_pct           numeric NOT NULL DEFAULT 0, -- employer NI/pension uplift, if known
  start_date            date NOT NULL,
  end_date              date,
  entity_id             int NOT NULL DEFAULT 1,
  realm                 text NOT NULL DEFAULT 'work',
  note                  text,
  updated_at            timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE salaried_staff ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS realm_isolation ON salaried_staff;
CREATE POLICY realm_isolation ON salaried_staff USING (
  CASE
    WHEN current_setting('app.current_realm', true) = 'owner' THEN true
    WHEN current_setting('app.current_realm', true) = 'work'  THEN realm IN ('work','shared')
    WHEN current_setting('app.current_realm', true) IS NULL
      OR current_setting('app.current_realm', true) = ''      THEN true
    ELSE realm = current_setting('app.current_realm', true)
  END
);
GRANT SELECT ON salaried_staff TO homeai_readonly;

INSERT INTO salaried_staff (name, workforce_external_id, position_title, annual_salary, start_date, entity_id, realm, note)
VALUES ('Karl Ramsey', '4978723', 'General Manager', 40000, '2026-05-20', 1, 'work',
        'GM salaried £40k from 2026-05-20. Salary is source of truth; his Tanda hourly shift cost is excluded from labour to avoid double-count.')
ON CONFLICT DO NOTHING;
