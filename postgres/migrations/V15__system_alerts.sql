-- V15: system_alerts table — sink for Prometheus/Alertmanager firing alerts.
--
-- Alertmanager POSTs alert groups to an n8n webhook; the workflow inserts
-- one row per individual alert, linking by fingerprint (Alertmanager's
-- stable per-alert identifier) so re-fired alerts UPSERT on the same row.
--
-- This is the placeholder sink for Phase 1 — Telegram delivery is added in
-- Phase 2 once the bot exists. Keeping the alert history in Postgres also
-- means the dashboard can show "alerts in last 24h by severity" without
-- depending on Alertmanager retention (default 5d).

\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS system_alerts (
  id              BIGSERIAL PRIMARY KEY,
  fingerprint     TEXT UNIQUE NOT NULL,         -- Alertmanager's stable hash per alert
  alertname       TEXT NOT NULL,
  severity        TEXT,
  status          TEXT NOT NULL,                -- firing | resolved
  starts_at       TIMESTAMPTZ NOT NULL,
  ends_at         TIMESTAMPTZ,                  -- NULL while firing; set on resolve
  generator_url   TEXT,
  summary         TEXT,
  description     TEXT,
  labels          JSONB,
  annotations     JSONB,
  first_seen_at   TIMESTAMPTZ DEFAULT NOW(),
  last_updated_at TIMESTAMPTZ DEFAULT NOW(),
  acknowledged    BOOLEAN DEFAULT FALSE,
  acknowledged_by TEXT,
  acknowledged_at TIMESTAMPTZ,
  notes           TEXT
);

CREATE INDEX IF NOT EXISTS idx_alerts_status_severity
  ON system_alerts (status, severity, last_updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_alerts_alertname
  ON system_alerts (alertname, status, last_updated_at DESC);

GRANT SELECT, INSERT, UPDATE ON system_alerts TO homeai_pipeline;
GRANT USAGE ON SEQUENCE system_alerts_id_seq TO homeai_pipeline;
GRANT SELECT ON system_alerts TO homeai_readonly;

SELECT 'system_alerts ready' AS check;
