-- =============================================================================
-- V191 — U173: VAT-relevant line classification (computed via rules)
-- =============================================================================
-- caterbook_room_nights is a view; can't ADD COLUMN. Approach:
-- - Rules table maps (source, pattern) → vat_rate
-- - Slug computes VAT at query time using JOIN to rules
-- - For touchoffice_department_sales (table), also add vat_rate column for
--   speed; backfill via trigger.
-- =============================================================================

BEGIN;

ALTER TABLE touchoffice_department_sales
  ADD COLUMN IF NOT EXISTS vat_rate NUMERIC(4,2);

CREATE TABLE IF NOT EXISTS vat_classification_rules (
  id           BIGSERIAL PRIMARY KEY,
  source_table TEXT NOT NULL,
  pattern      TEXT NOT NULL,
  vat_rate     NUMERIC(4,2) NOT NULL CHECK (vat_rate IN (0.00, 0.05, 0.20)),
  notes        TEXT,
  priority     INTEGER NOT NULL DEFAULT 100,
  active       BOOLEAN NOT NULL DEFAULT true,
  added_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  added_by     TEXT NOT NULL DEFAULT 'u173',
  UNIQUE (source_table, pattern)
);

INSERT INTO vat_classification_rules (source_table, pattern, vat_rate, notes, priority) VALUES
  ('caterbook_room_nights',         '%',               0.20, 'All rooms standard 20%', 100),
  ('touchoffice_department_sales', 'FOOD SALES',       0.20, 'In-house food standard',  100),
  ('touchoffice_department_sales', 'ALCOHOL SALES',    0.20, 'Alcohol standard',        100),
  ('touchoffice_department_sales', 'HOT DRINKS',       0.20, 'Hot drinks standard',     100),
  ('touchoffice_department_sales', 'Cafe Ice Cream',   0.20, 'Cafe ice cream',          100),
  ('touchoffice_department_sales', 'Cafe Soft Drinks', 0.20, 'Soft drinks standard',    100),
  ('touchoffice_department_sales', 'SNACK',            0.20, 'Snacks standard',         100),
  ('touchoffice_department_sales', 'ACCOM',            0.20, 'Pub food-on-bill',        100),
  ('touchoffice_department_sales', 'KITCHEN INT',      0.00, 'Internal transfer — exempt', 200),
  ('touchoffice_department_sales', 'DEPT 16',          0.20, 'Catch-all until known',   90),
  ('touchoffice_department_sales', 'DEPART 8',         0.20, 'Catch-all until known',   90)
ON CONFLICT (source_table, pattern) DO NOTHING;

-- Backfill touchoffice
UPDATE touchoffice_department_sales tds
   SET vat_rate = r.vat_rate
  FROM vat_classification_rules r
 WHERE r.source_table = 'touchoffice_department_sales'
   AND r.active
   AND tds.vat_rate IS NULL
   AND tds.department ILIKE r.pattern;

-- VAT owed for current quarter
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'vat_owed_quarter',
  'VAT owed — current quarter (output VAT from revenue)',
  'U173: per-rate output VAT for the current quarter so Jo sees running total.',
  E'WITH q AS (
      SELECT date_trunc(''quarter'', CURRENT_DATE)::date AS q_start,
             (date_trunc(''quarter'', CURRENT_DATE) + INTERVAL ''3 months'' - INTERVAL ''1 day'')::date AS q_end
    ),
    rooms_rule AS (
      SELECT vat_rate FROM vat_classification_rules
       WHERE source_table = ''caterbook_room_nights'' AND active LIMIT 1
    ),
    food AS (
      SELECT COALESCE(vat_rate, 0.20) AS rate,
             SUM(value) AS gross,
             SUM(value * COALESCE(vat_rate, 0.20) / (1 + COALESCE(vat_rate, 0.20)))::numeric(12,2) AS vat_amt
        FROM touchoffice_department_sales, q
       WHERE report_date BETWEEN q.q_start AND q.q_end
       GROUP BY COALESCE(vat_rate, 0.20)
    ),
    rooms AS (
      SELECT (SELECT vat_rate FROM rooms_rule) AS rate,
             SUM(rate_per_night) AS gross,
             SUM(rate_per_night * (SELECT vat_rate FROM rooms_rule) /
                 (1 + (SELECT vat_rate FROM rooms_rule)))::numeric(12,2) AS vat_amt
        FROM caterbook_room_nights, q
       WHERE night_date BETWEEN q.q_start AND q.q_end
    )
    SELECT ''food_drink''::text AS source, rate, gross::numeric(12,2) AS gross_gbp, vat_amt AS vat_due_gbp FROM food
    UNION ALL
    SELECT ''rooms''::text, rate, gross::numeric(12,2), vat_amt FROM rooms
    ORDER BY source, rate',
  '{}', 'shared', true, NOW(), 'u173', 'u173'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'vat_unclassified_lines_30d',
  'VAT — unclassified TouchOffice lines (last 30d)',
  'U173: revenue lines where vat_rate is NULL — needs a rule.',
  E'SELECT department, count(*) AS lines, SUM(value)::numeric(12,2) AS gross
      FROM touchoffice_department_sales
     WHERE report_date > CURRENT_DATE - 30
       AND vat_rate IS NULL
     GROUP BY department ORDER BY 3 DESC',
  '{}', 'shared', true, NOW(), 'u173', 'u173'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

COMMIT;
