-- ============================================================
-- U38 — Add schema_version to audit_log
-- ============================================================
-- Tracks which JSON schema generation each AI worker is on.
-- Format: '<filename>@<git-sha-7>', e.g. 'email-classifier.schema.json@dc22278'.
-- Per SPEC §7.3.
-- ============================================================

ALTER TABLE audit_log ADD COLUMN IF NOT EXISTS schema_version TEXT;

CREATE INDEX IF NOT EXISTS idx_audit_log_schema_version
  ON audit_log (schema_version)
  WHERE schema_version IS NOT NULL;

COMMENT ON COLUMN audit_log.schema_version IS
  'Versioned identifier of the JSON Schema the AI worker was using when this row was written. Format: <file>@<git_sha_7>. NULL for rows pre-V44.';
