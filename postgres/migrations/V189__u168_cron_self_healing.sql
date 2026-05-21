-- =============================================================================
-- V189 — U168: cron self-healing — job tracking + missed-run detection
-- =============================================================================
-- Today's discovery: caterbook 07:00 cron failed 2 days in a row because
-- google-fetch threw HTTP 500. The hardened u28-caterbook-daily.sh logged
-- the failures but didn't auto-retry. Add a job-tracking table + a watcher
-- that retries failed cron jobs within their grace window.
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS cron_job_runs (
  id            BIGSERIAL PRIMARY KEY,
  job_name      TEXT NOT NULL,
  expected_at   TIMESTAMPTZ NOT NULL,
  started_at    TIMESTAMPTZ,
  completed_at  TIMESTAMPTZ,
  status        TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','running','success','failed','retried')),
  exit_code     INTEGER,
  log_excerpt   TEXT,
  attempt       INTEGER NOT NULL DEFAULT 1,
  realm         TEXT NOT NULL DEFAULT 'work'
                  CHECK (realm IN ('owner','work','personal','shared'))
);

CREATE INDEX IF NOT EXISTS idx_cron_job_runs_recent
  ON cron_job_runs (job_name, expected_at DESC);
CREATE INDEX IF NOT EXISTS idx_cron_job_runs_pending
  ON cron_job_runs (status, expected_at)
  WHERE status IN ('pending','failed');

-- Job catalog: what cron jobs to track + grace windows
CREATE TABLE IF NOT EXISTS cron_job_catalog (
  job_name        TEXT PRIMARY KEY,
  cron_expr       TEXT NOT NULL,
  command         TEXT NOT NULL,
  grace_minutes   INTEGER NOT NULL DEFAULT 120,
  max_retries     INTEGER NOT NULL DEFAULT 3,
  realm           TEXT NOT NULL DEFAULT 'work'
                    CHECK (realm IN ('owner','work','personal','shared')),
  active          BOOLEAN NOT NULL DEFAULT true,
  added_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Seed with critical jobs that benefit from auto-retry
INSERT INTO cron_job_catalog (job_name, cron_expr, command, grace_minutes, realm) VALUES
  ('u28-caterbook-daily',  '0 7 * * *',  '/home_ai/scripts/u28-caterbook-daily.sh',   180, 'work'),
  ('u128-xero-parse',      '0 7 * * *',  '/home_ai/scripts/u128-xero-parse.sh',       180, 'work'),
  ('u128-xero-export',     '45 6 * * *', '/home_ai/scripts/u128-xero-export.sh',      180, 'work'),
  ('u159-revenue-email',   '0 9 * * *',  '/home_ai/scripts/u159-revenue-email.sh',    180, 'work'),
  ('u166-dq-digest',       '0 6 * * *',  '/home_ai/scripts/u166-data-quality-digest.sh', 60, 'work'),
  ('u133-scrape-tides',    '0 6 * * *',  '/home_ai/scripts/u133-scrape-tides.py',     120, 'work'),
  ('u135-dojo-inbox',      '30 5 * * *', '/home_ai/scripts/u135-dojo-inbox-sweep.sh', 120, 'work')
ON CONFLICT (job_name) DO UPDATE SET cron_expr = EXCLUDED.cron_expr;

-- Slug: jobs missed today (expected to have run by now but no success)
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'cron_jobs_missed_today',
  'Cron jobs — missed today',
  'U168: jobs expected to have run by now but no success record.',
  E'WITH expected AS (
      SELECT j.job_name, j.cron_expr, j.command, j.grace_minutes
        FROM cron_job_catalog j WHERE j.active = true
    ),
    today_runs AS (
      SELECT job_name, max(completed_at) AS last_success
        FROM cron_job_runs
       WHERE status = ''success'' AND completed_at::date = CURRENT_DATE
       GROUP BY job_name
    )
    SELECT
      e.job_name, e.cron_expr, e.command,
      t.last_success,
      EXTRACT(HOUR FROM CURRENT_TIME) AS hour_now
      FROM expected e
      LEFT JOIN today_runs t USING (job_name)
     WHERE t.last_success IS NULL
       AND e.cron_expr NOT LIKE ''%/%''   -- skip frequent jobs
     ORDER BY e.cron_expr',
  '{}', 'shared', true, NOW(), 'u168', 'u168'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

-- Slug: failed-job log for last 7 days
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'cron_failures_7d',
  'Cron failures — last 7 days',
  'U168: failed/retried runs over last 7 days, with exit code + log excerpt.',
  E'SELECT job_name, expected_at, status, exit_code, attempt, substr(log_excerpt, 1, 200) AS excerpt
      FROM cron_job_runs
     WHERE expected_at > NOW() - INTERVAL ''7 days''
       AND status IN (''failed'',''retried'')
     ORDER BY expected_at DESC',
  '{}', 'shared', true, NOW(), 'u168', 'u168'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

COMMIT;
