-- ============================================================
-- U36 — Dreaming heuristics + AI worker drift + model inventory log
-- ============================================================
-- 1. dreaming_heuristics:  proposed/accepted rules from nightly audit_log mining
-- 2. dreaming_runs:        one row per nightly run for audit
-- 3. v_ai_worker_drift:    last 1h confidence vs 7d baseline (same hour-of-day)
-- 4. model_inventory_log:  weekly snapshot of Ollama /api/tags output
-- ============================================================

-- ── 1. dreaming_heuristics ───────────────────────────────────
CREATE TABLE IF NOT EXISTS dreaming_heuristics (
  id              BIGSERIAL PRIMARY KEY,
  generated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  scope           TEXT NOT NULL,                           -- e.g. 'gmail-classifier', 'invoice-extract'
  ai_worker       TEXT,                                     -- pipeline + node, optional
  observation     TEXT NOT NULL,                            -- what Sonnet noticed
  suggested_rule  TEXT NOT NULL,                            -- the proposed prompt-engineering tweak
  severity        TEXT NOT NULL DEFAULT 'low'
                  CHECK (severity IN ('low','medium','high')),
  status          TEXT NOT NULL DEFAULT 'proposed'
                  CHECK (status IN ('proposed','accepted','rejected','superseded')),
  raw_pattern     JSONB,                                    -- the source rows from audit_log
  reviewed_at     TIMESTAMPTZ,
  reviewed_by     TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_dh_status     ON dreaming_heuristics (status, severity, generated_at DESC);
CREATE INDEX IF NOT EXISTS idx_dh_scope      ON dreaming_heuristics (scope, status);

GRANT SELECT, INSERT, UPDATE ON dreaming_heuristics TO homeai_pipeline;
GRANT SELECT ON dreaming_heuristics TO homeai_readonly;
GRANT SELECT ON dreaming_heuristics TO metabase_app;
GRANT USAGE, SELECT ON SEQUENCE dreaming_heuristics_id_seq TO homeai_pipeline;

-- ── 2. dreaming_runs ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS dreaming_runs (
  id              BIGSERIAL PRIMARY KEY,
  started_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at     TIMESTAMPTZ,
  audit_window_h  INT NOT NULL DEFAULT 24,
  patterns_found  INT,
  proposals_new   INT,
  ai_input_tokens INT,
  ai_output_tokens INT,
  ai_cache_hits   INT,
  error_message   TEXT
);
CREATE INDEX IF NOT EXISTS idx_dr_started ON dreaming_runs (started_at DESC);

GRANT SELECT, INSERT, UPDATE ON dreaming_runs TO homeai_pipeline;
GRANT SELECT ON dreaming_runs TO homeai_readonly;
GRANT USAGE, SELECT ON SEQUENCE dreaming_runs_id_seq TO homeai_pipeline;

-- ── 3. v_ai_worker_drift ─────────────────────────────────────
-- Compare last hour's avg confidence vs the 7-day rolling baseline for the
-- SAME hour-of-day (controls for diurnal patterns — pipelines fire on cron).
-- Flag if today_avg is below baseline_avg - 2*baseline_stddev.
CREATE OR REPLACE VIEW v_ai_worker_drift AS
WITH recent AS (
  SELECT
    ai_worker,
    ai_model,
    AVG((ai_parsed->>'confidence_score')::numeric) AS today_avg_conf,
    COUNT(*) AS today_n
  FROM audit_log
  WHERE created_at >= now() - interval '1 hour'
    AND ai_parsed ? 'confidence_score'
    AND ai_worker IS NOT NULL
    AND ai_model IS NOT NULL
  GROUP BY ai_worker, ai_model
),
baseline AS (
  SELECT
    ai_worker,
    ai_model,
    AVG((ai_parsed->>'confidence_score')::numeric)    AS base_avg,
    STDDEV((ai_parsed->>'confidence_score')::numeric) AS base_std,
    COUNT(*) AS base_n
  FROM audit_log
  WHERE created_at <  now() - interval '1 hour'
    AND created_at >= now() - interval '7 days'
    AND EXTRACT(hour FROM created_at) = EXTRACT(hour FROM now())  -- diurnal control
    AND ai_parsed ? 'confidence_score'
    AND ai_worker IS NOT NULL
    AND ai_model IS NOT NULL
  GROUP BY ai_worker, ai_model
)
SELECT
  r.ai_worker,
  r.ai_model,
  r.today_avg_conf,
  r.today_n,
  b.base_avg AS baseline_avg_conf,
  b.base_std AS baseline_stddev,
  b.base_n   AS baseline_n,
  ROUND(((r.today_avg_conf - b.base_avg) / NULLIF(b.base_std, 0))::numeric, 2) AS delta_stddev,
  CASE
    WHEN b.base_std IS NULL OR b.base_std = 0 THEN false
    WHEN r.today_avg_conf < (b.base_avg - 2 * b.base_std) THEN true
    ELSE false
  END AS flagged
FROM recent r
LEFT JOIN baseline b USING (ai_worker, ai_model)
ORDER BY flagged DESC, delta_stddev ASC NULLS LAST;

GRANT SELECT ON v_ai_worker_drift TO homeai_pipeline;
GRANT SELECT ON v_ai_worker_drift TO homeai_readonly;
GRANT SELECT ON v_ai_worker_drift TO metabase_app;

-- ── 4. model_inventory_log ───────────────────────────────────
CREATE TABLE IF NOT EXISTS model_inventory_log (
  id              BIGSERIAL PRIMARY KEY,
  snapshot_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  model_name      TEXT NOT NULL,
  size_bytes      BIGINT,
  parameter_size  TEXT,
  quantization    TEXT,
  modified_at     TIMESTAMPTZ,
  raw_payload     JSONB
);
CREATE INDEX IF NOT EXISTS idx_mil_snapshot ON model_inventory_log (snapshot_at DESC);
CREATE INDEX IF NOT EXISTS idx_mil_model    ON model_inventory_log (model_name, snapshot_at DESC);

GRANT SELECT, INSERT ON model_inventory_log TO homeai_pipeline;
GRANT SELECT ON model_inventory_log TO homeai_readonly;
GRANT USAGE, SELECT ON SEQUENCE model_inventory_log_id_seq TO homeai_pipeline;
