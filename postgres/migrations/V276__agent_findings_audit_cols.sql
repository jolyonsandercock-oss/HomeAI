-- postgres/migrations/V276__agent_findings_audit_cols.sql
-- System auditor: severity/status/fingerprint for dedup + auto-resolve rendering.
ALTER TABLE cognition.agent_findings
  ADD COLUMN IF NOT EXISTS severity     text,
  ADD COLUMN IF NOT EXISTS status       text DEFAULT 'firing',
  ADD COLUMN IF NOT EXISTS fingerprint  text,
  ADD COLUMN IF NOT EXISTS last_seen_at timestamptz DEFAULT now();
CREATE UNIQUE INDEX IF NOT EXISTS agent_findings_fingerprint_uq
  ON cognition.agent_findings (fingerprint) WHERE fingerprint IS NOT NULL;
