-- ============================================================
-- U32 — staff_meta: hourly rate + on-cost multiplier per worker
-- ============================================================
-- Cost-per-employee mapping for Labour % + SPLH calculations.
-- Keyed on workforce_users.external_id so it survives re-syncs.
--
-- Rate stored in PENCE (integer) to avoid float drift across joins.
-- On-cost default 12.5 = UK NI employer (9%) + workplace pension (3.5%).
-- Tunable per-row if some staff have salary-sacrifice or different bands.
-- ============================================================

CREATE TABLE staff_meta (
  user_external_id   BIGINT PRIMARY KEY,           -- FK to workforce_users(external_id), enforced in code
  entity_id          INT NOT NULL DEFAULT 1,
  hourly_rate_pence  INT,                          -- e.g. £15.50/h → 1550
  on_cost_pct        NUMERIC(5,2) NOT NULL DEFAULT 12.5,
  role_tags          JSONB DEFAULT '[]'::jsonb,    -- e.g. ["kitchen","bar","manager"]
  notes              TEXT,
  source             TEXT NOT NULL DEFAULT 'unset' -- 'tanda' | 'manual' | 'unset'
                     CHECK (source IN ('tanda','manual','unset','imported')),
  rate_observed_at   TIMESTAMPTZ,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_staff_meta_entity ON staff_meta (entity_id);
CREATE INDEX idx_staff_meta_source ON staff_meta (source);

ALTER TABLE staff_meta ENABLE ROW LEVEL SECURITY;
CREATE POLICY entity_isolation ON staff_meta
  USING (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all'   THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$' THEN entity_id = current_setting('app.current_entity', true)::int
      ELSE false
    END)
  WITH CHECK (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all'   THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$' THEN entity_id = current_setting('app.current_entity', true)::int
      ELSE false
    END);

GRANT SELECT, INSERT, UPDATE, DELETE ON staff_meta TO homeai_pipeline;
GRANT SELECT ON staff_meta TO homeai_readonly;

-- Convenience view: every workforce_user joined to their meta (left join)
CREATE OR REPLACE VIEW v_staff_with_meta AS
SELECT
  u.external_id,
  u.full_name,
  u.email,
  u.active,
  u.hire_date,
  u.termination_date,
  COALESCE(m.hourly_rate_pence, 0)              AS hourly_rate_pence,
  ROUND(COALESCE(m.hourly_rate_pence, 0) / 100.0, 2) AS hourly_rate_gbp,
  COALESCE(m.on_cost_pct, 12.5)                  AS on_cost_pct,
  COALESCE(m.role_tags, '[]'::jsonb)             AS role_tags,
  COALESCE(m.source, 'unset')                    AS rate_source,
  m.rate_observed_at,
  m.notes
FROM workforce_users u
LEFT JOIN staff_meta  m ON m.user_external_id = u.external_id;

GRANT SELECT ON v_staff_with_meta TO homeai_pipeline, homeai_readonly;
