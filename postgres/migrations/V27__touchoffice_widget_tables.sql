-- ============================================================
-- U27 — TouchOffice home-widget tables (Pipeline 5)
-- ============================================================
-- Three datasets per (site, report_date) come from the scraper:
--   touchoffice_fixed_totals     one row per totaliser (NET sales, CASH, etc.)
--   touchoffice_department_sales one row per department
--   touchoffice_plu_sales        one row per PLU
-- Plus a log table to record each scrape attempt.
--
-- entity_id defaults to 1 (Atlantic Road Trading Ltd) — both Malthouse (pub)
-- and Sandwich Bar (ice cream shop) sit under Trading Ltd. RLS policy
-- mirrors epos_daily_reports.
-- ============================================================

-- ── 1. fixed_totals ─────────────────────────────────────────
CREATE TABLE touchoffice_fixed_totals (
  id              BIGSERIAL PRIMARY KEY,
  idempotency_key TEXT NOT NULL UNIQUE,
  event_id        BIGINT,
  entity_id       INT NOT NULL DEFAULT 1,
  site            TEXT NOT NULL CHECK (site IN ('malthouse','sandwich','head_office')),
  report_date     DATE NOT NULL,
  totaliser_id    INT NOT NULL,
  label           TEXT NOT NULL,
  quantity        NUMERIC(14,2),
  value           NUMERIC(14,2),
  raw_cells       JSONB,
  scraped_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (site, report_date, totaliser_id)
);
CREATE INDEX idx_to_ft_site_date ON touchoffice_fixed_totals (site, report_date);

ALTER TABLE touchoffice_fixed_totals ENABLE ROW LEVEL SECURITY;
CREATE POLICY entity_isolation ON touchoffice_fixed_totals
  USING (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all'        THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$'      THEN entity_id = current_setting('app.current_entity', true)::int
      ELSE false
    END)
  WITH CHECK (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all'        THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$'      THEN entity_id = current_setting('app.current_entity', true)::int
      ELSE false
    END);

-- ── 2. department_sales ─────────────────────────────────────
CREATE TABLE touchoffice_department_sales (
  id              BIGSERIAL PRIMARY KEY,
  idempotency_key TEXT NOT NULL UNIQUE,
  event_id        BIGINT,
  entity_id       INT NOT NULL DEFAULT 1,
  site            TEXT NOT NULL CHECK (site IN ('malthouse','sandwich','head_office')),
  report_date     DATE NOT NULL,
  department      TEXT NOT NULL,
  quantity        NUMERIC(14,2),
  value           NUMERIC(14,2),
  raw_cells       JSONB,
  scraped_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (site, report_date, department)
);
CREATE INDEX idx_to_ds_site_date ON touchoffice_department_sales (site, report_date);

ALTER TABLE touchoffice_department_sales ENABLE ROW LEVEL SECURITY;
CREATE POLICY entity_isolation ON touchoffice_department_sales
  USING (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all'        THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$'      THEN entity_id = current_setting('app.current_entity', true)::int
      ELSE false
    END)
  WITH CHECK (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all'        THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$'      THEN entity_id = current_setting('app.current_entity', true)::int
      ELSE false
    END);

-- ── 3. plu_sales ────────────────────────────────────────────
CREATE TABLE touchoffice_plu_sales (
  id              BIGSERIAL PRIMARY KEY,
  idempotency_key TEXT NOT NULL UNIQUE,
  event_id        BIGINT,
  entity_id       INT NOT NULL DEFAULT 1,
  site            TEXT NOT NULL CHECK (site IN ('malthouse','sandwich','head_office')),
  report_date     DATE NOT NULL,
  plu_number      TEXT NOT NULL,
  descriptor      TEXT NOT NULL,
  quantity        NUMERIC(14,2),
  value           NUMERIC(14,2),
  raw_cells       JSONB,
  scraped_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (site, report_date, plu_number)
);
CREATE INDEX idx_to_plu_site_date ON touchoffice_plu_sales (site, report_date);

ALTER TABLE touchoffice_plu_sales ENABLE ROW LEVEL SECURITY;
CREATE POLICY entity_isolation ON touchoffice_plu_sales
  USING (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all'        THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$'      THEN entity_id = current_setting('app.current_entity', true)::int
      ELSE false
    END)
  WITH CHECK (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all'        THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$'      THEN entity_id = current_setting('app.current_entity', true)::int
      ELSE false
    END);

-- ── 4. scrape log (one row per (site, date, widget) attempt) ─
CREATE TABLE touchoffice_scrapes (
  id              BIGSERIAL PRIMARY KEY,
  entity_id       INT NOT NULL DEFAULT 1,
  site            TEXT NOT NULL,
  report_date     DATE NOT NULL,
  widget          TEXT NOT NULL CHECK (widget IN ('fixed_totals','department_sales','plu_sales')),
  scraped_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  success         BOOLEAN NOT NULL,
  rows_written    INT,
  error_message   TEXT,
  scrape_runtime_ms INT,
  snapshot_html_path TEXT,
  snapshot_png_path  TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_to_scrapes_site_date ON touchoffice_scrapes (site, report_date, widget);

ALTER TABLE touchoffice_scrapes ENABLE ROW LEVEL SECURITY;
CREATE POLICY entity_isolation ON touchoffice_scrapes
  USING (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all'        THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$'      THEN entity_id = current_setting('app.current_entity', true)::int
      ELSE false
    END)
  WITH CHECK (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all'        THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$'      THEN entity_id = current_setting('app.current_entity', true)::int
      ELSE false
    END);

-- ── 5. Grants — homeai_pipeline writes; homeai_readonly reads ─
GRANT SELECT, INSERT, UPDATE, DELETE ON
  touchoffice_fixed_totals,
  touchoffice_department_sales,
  touchoffice_plu_sales,
  touchoffice_scrapes
TO homeai_pipeline;

GRANT USAGE, SELECT ON
  touchoffice_fixed_totals_id_seq,
  touchoffice_department_sales_id_seq,
  touchoffice_plu_sales_id_seq,
  touchoffice_scrapes_id_seq
TO homeai_pipeline;

GRANT SELECT ON
  touchoffice_fixed_totals,
  touchoffice_department_sales,
  touchoffice_plu_sales,
  touchoffice_scrapes
TO homeai_readonly;
