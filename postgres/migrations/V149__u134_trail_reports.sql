-- =============================================================================
-- V149 — U134 T1: trail_reports + trail_reports_today + trail_reports_trend_14d
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS trail_reports (
    id              BIGSERIAL PRIMARY KEY,
    trail_report_id TEXT NOT NULL,
    location        TEXT NOT NULL,           -- 'malthouse' | 'cafe' | etc.
    report_name     TEXT NOT NULL,           -- 'Opening Checks', 'Closing Checks'
    report_date     DATE NOT NULL,
    cadence         TEXT NOT NULL CHECK (cadence IN ('daily','weekly','adhoc')),
    score_pct       NUMERIC(5,2),
    tasks_total     INTEGER,
    tasks_completed INTEGER,
    tasks_overdue   INTEGER,
    raw_payload     JSONB,
    ingested_at     TIMESTAMPTZ DEFAULT now(),
    realm           TEXT NOT NULL DEFAULT 'work',
    UNIQUE (trail_report_id, report_date)
);
CREATE INDEX IF NOT EXISTS idx_trail_reports_date
    ON trail_reports (report_date DESC);
CREATE INDEX IF NOT EXISTS idx_trail_reports_location_date
    ON trail_reports (location, report_date DESC);

INSERT INTO query_whitelist
    (slug, display_name, description, sql_template, param_schema, result_format,
     active, created_by, approved_at, approved_by, notes, realm)
VALUES
    ('trail_reports_today',
     'Trail compliance reports — today',
     'Latest Trail report state per (location, report_name) for a target date (defaults today).',
     $sql$SELECT trail_report_id, location, report_name, cadence,
                score_pct, tasks_total, tasks_completed, tasks_overdue,
                report_date
           FROM trail_reports
          WHERE report_date = COALESCE(:date::date, CURRENT_DATE)
          ORDER BY location, report_name$sql$,
     '{"date": {"type":"string","format":"date","optional":true}}'::jsonb,
     'table', true, 'V149-U134T1', NOW(), 'V149-U134T1',
     'Per U134 T1 plan.', 'work'),
    ('trail_reports_trend_14d',
     'Trail score trend — 14 days',
     '14-day score timeseries for a report_name (param) — drives sparkline.',
     $sql$SELECT report_date, location, score_pct
           FROM trail_reports
          WHERE report_name = :report_name
            AND report_date >= CURRENT_DATE - 14
          ORDER BY report_date$sql$,
     '{"report_name": {"type":"string","required":true}}'::jsonb,
     'table', true, 'V149-U134T1', NOW(), 'V149-U134T1',
     'Per U134 T1 plan — sparkline data.', 'work')
ON CONFLICT (slug) DO UPDATE
   SET sql_template = EXCLUDED.sql_template,
       param_schema = EXCLUDED.param_schema,
       active       = true,
       approved_at  = NOW();

COMMIT;
