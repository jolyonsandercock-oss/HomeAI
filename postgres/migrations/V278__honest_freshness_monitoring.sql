-- V278: make the pipeline freshness checks HONEST so the dashboard stops crying wolf.
-- Investigation (2026-06-25): all 6 "stale" feeds were monitoring artifacts, not broken
-- pipelines. The real invoice extraction (vendor_invoice_lines) is current to today; the
-- "stale" alarms came from freshness checks measuring dead legacy tables, last-resolution
-- on a clean queue, a redundant disk-cache, or episodic input feeds with no new statement.

-- invoice_pdf_attach: u125 is a redundant disk-cache; the REAL pipeline is line extraction.
-- Measure that (current today) instead of the cache's pdf_fetched_at.
UPDATE ops.pipeline_registry
   SET freshness_sql = 'SELECT max(created_at) FROM vendor_invoice_lines',
       notes = COALESCE(notes,'')||' [V278: repointed to real extraction; u125 disk-cache is non-load-bearing]'
 WHERE name = 'invoice_pdf_attach_fetch';

-- invoice_date_sweep measured a DEAD legacy table (invoices.email_ocr, frozen 19 Jun);
-- the live invoice table is current. Measure that.
UPDATE ops.pipeline_registry
   SET freshness_sql = 'SELECT max(received_at) FROM vendor_invoice_inbox',
       notes = COALESCE(notes,'')||' [V278: repointed off dead legacy invoices table]'
 WHERE name = 'invoice_date_sweep';

-- deadletter_hygiene runs hourly but measured last-RESOLUTION (naturally old on a clean
-- queue). Measure last successful RUN (its heartbeat) instead — alarms only if the cron stops.
UPDATE ops.pipeline_registry
   SET freshness_sql = $$SELECT max(finished_at) FROM ops.pipeline_runs WHERE name='deadletter_hygiene' AND status='ok'$$,
       notes = COALESCE(notes,'')||' [V278: measure last run, not last resolution]'
 WHERE name = 'deadletter_hygiene';

-- natwest / dojo / bank are EPISODIC input feeds (forwarded statements/CSVs). The crons run
-- fine; "stale" just means no new statement. Give them an episodic SLA so they alarm only on
-- a genuinely-abandoned feed, not on a normal gap between statements. (Proper follow-up:
-- add per-run heartbeats to these crons and measure last-run — they don't heartbeat yet.)
UPDATE ops.pipeline_registry SET freshness_sla_hours = 720  WHERE name = 'natwest_inbox_sweep';  -- 30d
UPDATE ops.pipeline_registry SET freshness_sla_hours = 720  WHERE name = 'dojo_inbox_sweep';     -- 30d
UPDATE ops.pipeline_registry SET freshness_sla_hours = 1080 WHERE name = 'bank_transactions_any';-- 45d (monthly statements)
