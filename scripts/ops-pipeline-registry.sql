-- ops-pipeline-registry.sql — Phase 0 keystone of the Option B consolidation.
-- The single source of truth for "what pipelines exist, when they run, are they fresh".
-- Idempotent. Apply: psql ... -f this file. Freshness checked by pipeline-freshness-check.py.
CREATE SCHEMA IF NOT EXISTS ops;

CREATE TABLE IF NOT EXISTS ops.pipeline_registry (
  name                 text PRIMARY KEY,
  kind                 text,                 -- scrape | sweep | sync | import | extract
  script_path          text,
  schedule_cron        text,                 -- crontab spec, or 'manual' / 'n8n'
  target_rel           text,                 -- relation whose freshness we measure
  freshness_sql        text,                 -- returns one timestamptz = newest data
  freshness_sla_hours  numeric,              -- alert if newest data older than this
  enabled              boolean DEFAULT true,
  owner                text DEFAULT 'joly',
  notes                text,
  created_at           timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ops.pipeline_runs (
  id            bigserial PRIMARY KEY,
  name          text REFERENCES ops.pipeline_registry(name),
  started_at    timestamptz,
  finished_at   timestamptz DEFAULT now(),
  status        text,                        -- ok | fail | skip
  rows_affected integer,
  note          text
);
CREATE INDEX IF NOT EXISTS idx_pipeline_runs_name_time ON ops.pipeline_runs(name, finished_at DESC);

-- Seed the data pipelines (from SYSTEM_ARCHITECTURE.md §2). freshness_sql returns newest data ts.
INSERT INTO ops.pipeline_registry (name, kind, script_path, schedule_cron, target_rel, freshness_sql, freshness_sla_hours, notes) VALUES
 ('touchoffice_realtime','scrape','scripts/u33-touchoffice-realtime.sh','*/15 * * * *','touchoffice_department_sales',
    'SELECT max(report_date)::timestamptz FROM touchoffice_department_sales',26,'sales by dept; head_office=truth'),
 ('touchoffice_headoffice_backfill','scrape','scripts/u274-touchoffice-headoffice-backfill.sh','13 4 * * *','touchoffice_department_sales',
    'SELECT max(scraped_at) FROM touchoffice_department_sales WHERE site=''head_office''',30,'consolidated revenue self-heal'),
 ('workforce_sync','sync','scripts/u29-workforce-sync.sh','0 7 * * *','workforce_shifts',
    'SELECT max(shift_date)::timestamptz FROM workforce_shifts',30,'Tanda/Workforce labour'),
 ('tanda_timesheets','sync','scripts/u47-tanda-timesheets-sync.sh','20 2 * * *','workforce_timesheets',
    'SELECT max(last_synced_at) FROM workforce_timesheets',30,'timesheets'),
 ('caterbook_daily','sync','scripts/u28-caterbook-daily.sh','30 7 * * *','accommodation_bookings',
    'SELECT max(created_at) FROM accommodation_bookings',30,'arrivals/departures'),
 ('caterbook_guest_sync','sync','scripts/u286-caterbook-guest-sync.sh','37 5 * * *','accommodation_bookings',
    'SELECT max(updated_at) FROM accommodation_bookings',30,'guest contact backfill'),
 ('dojo_inbox_sweep','import','scripts/u135-dojo-inbox-sweep.sh','15 7 * * *','dojo_transactions',
    'SELECT max(transaction_date)::timestamptz FROM dojo_transactions',48,'STARVED since ~06-15 — no CSVs'),
 ('invoice_harvester','sweep','scripts/u95-harvest-all-invoices.py','50 6 * * *','vendor_invoice_inbox',
    'SELECT max(ingested_at) FROM vendor_invoice_inbox',30,'BROKEN (503) — verify container'),
 ('invoice_pdf_attach_fetch','sweep','scripts/u125-pdf-attachment-fetch.sh','5 * * * *','vendor_invoice_inbox',
    'SELECT max(pdf_fetched_at) FROM vendor_invoice_inbox',12,'fetch PDFs for new invoices (stalls on google-fetch DNS)'),
 ('invoice_date_sweep','extract','scripts/u-invoice-pdf-date-sweep.sh','10 7 * * *','invoices',
    'SELECT max(created_at) FROM invoices WHERE source=''email_ocr''',48,'pdfplumber->gemma4-doc (NEW)'),
 ('invoice_line_sweep','extract','scripts/u-invoice-line-sweep.sh','40 7 * * *','vendor_invoice_lines',
    'SELECT max(created_at) FROM vendor_invoice_lines',48,'pdfplumber->qwen2.5:72b (NEW)'),
 ('natwest_inbox_sweep','import','scripts/u-natwest-inbox-sweep.sh','manual','bank_transactions',
    'SELECT max(transaction_date)::timestamptz FROM bank_transactions WHERE source=''natwest_csv''',72,'UNSCHEDULED — Phase 2.2'),
 ('bank_transactions_any','import',NULL,'mixed','bank_transactions',
    'SELECT max(transaction_date)::timestamptz FROM bank_transactions',72,'overall bank ledger freshness')
ON CONFLICT (name) DO UPDATE SET
  kind=EXCLUDED.kind, script_path=EXCLUDED.script_path, schedule_cron=EXCLUDED.schedule_cron,
  target_rel=EXCLUDED.target_rel, freshness_sql=EXCLUDED.freshness_sql,
  freshness_sla_hours=EXCLUDED.freshness_sla_hours, notes=EXCLUDED.notes;

-- Freshness probe: loop the registry, run each pipeline's freshness_sql, classify.
-- The watchdog cron does: SELECT * FROM ops.check_freshness() WHERE status<>'ok' -> alert.
CREATE OR REPLACE FUNCTION ops.check_freshness()
RETURNS TABLE(name text, newest timestamptz, sla_hours numeric, age_hours numeric, status text) AS $$
DECLARE r record; ts timestamptz;
BEGIN
  FOR r IN SELECT pr.name AS n, pr.freshness_sql AS q, pr.freshness_sla_hours AS sla
           FROM ops.pipeline_registry pr WHERE pr.enabled ORDER BY pr.name LOOP
    BEGIN EXECUTE r.q INTO ts; EXCEPTION WHEN OTHERS THEN ts := NULL; END;
    name := r.n; newest := ts; sla_hours := r.sla;
    age_hours := CASE WHEN ts IS NULL THEN NULL ELSE round(EXTRACT(EPOCH FROM (now()-ts))/3600.0,1) END;
    status := CASE WHEN ts IS NULL THEN 'NO_DATA'
                   WHEN now()-ts > make_interval(hours => r.sla::int) THEN 'STALE'
                   ELSE 'ok' END;
    RETURN NEXT;
  END LOOP;
END $$ LANGUAGE plpgsql;
