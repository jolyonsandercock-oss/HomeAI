-- V269: ops.record_pipeline_run() — the run-heartbeat layer on top of the
-- existing data-freshness watchdogs (ops.check_freshness). Pipelines (cron or
-- n8n) call this to record start/finish/status/rows on each run, so silent
-- "did it even run?" failures become visible. FK: name must exist in
-- ops.pipeline_registry. SECURITY DEFINER so low-privilege roles can record.
-- Wrapper: scripts/ops-run.sh <name> -- <command...>.
CREATE OR REPLACE FUNCTION ops.record_pipeline_run(
  p_name    text,
  p_status  text        DEFAULT 'ok',
  p_started timestamptz DEFAULT now(),
  p_rows    int         DEFAULT NULL,
  p_note    text        DEFAULT NULL)
RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = ops, public AS $$
  INSERT INTO ops.pipeline_runs(name, started_at, finished_at, status, rows_affected, note)
  VALUES (p_name, p_started, now(), p_status, p_rows, left(p_note, 500));
$$;

GRANT EXECUTE ON FUNCTION ops.record_pipeline_run(text,text,timestamptz,int,text) TO homeai_pipeline;
