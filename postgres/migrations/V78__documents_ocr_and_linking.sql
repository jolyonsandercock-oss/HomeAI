-- =============================================================================
-- V78 — Document OCR + entity linking (U61 T4)
-- =============================================================================
-- Extend `documents` with:
--   * paperless_id    — set later when Paperless-ngx is wired
--   * file_path       — local on-disk path (when not in Drive)
--   * mime_type       — application/pdf, image/jpeg, image/png, image/tiff
--   * sha256          — content hash (idempotency on upload)
--   * ocr_text        — OCR + pdfplumber text for FTS
--   * ocr_tsv         — generated tsvector for full-text search
--   * linked_table    — 'vehicles' | 'properties' | 'children' | 'invoices' | 'employees'
--   * linked_id       — FK in that table; soft reference (no FK constraint)
--   * linked_by       — 'auto:plate_regex' | 'auto:postcode' | 'auto:name' | 'manual'
--   * uploaded_by
-- =============================================================================

BEGIN;

ALTER TABLE documents
    ADD COLUMN IF NOT EXISTS paperless_id INTEGER,
    ADD COLUMN IF NOT EXISTS file_path    TEXT,
    ADD COLUMN IF NOT EXISTS mime_type    TEXT,
    ADD COLUMN IF NOT EXISTS sha256       TEXT,
    ADD COLUMN IF NOT EXISTS ocr_text     TEXT,
    ADD COLUMN IF NOT EXISTS linked_table TEXT,
    ADD COLUMN IF NOT EXISTS linked_id    INTEGER,
    ADD COLUMN IF NOT EXISTS linked_by    TEXT,
    ADD COLUMN IF NOT EXISTS uploaded_by  TEXT;

-- sha256 uniqueness for idempotent uploads
CREATE UNIQUE INDEX IF NOT EXISTS uq_documents_sha256
    ON documents (sha256) WHERE sha256 IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_documents_paperless_id
    ON documents (paperless_id) WHERE paperless_id IS NOT NULL;

-- Linked-entity lookups
CREATE INDEX IF NOT EXISTS idx_documents_link
    ON documents (linked_table, linked_id);

-- FTS index over OCR text. Stored generated column for speed.
ALTER TABLE documents
    ADD COLUMN IF NOT EXISTS ocr_tsv tsvector
    GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(title,'')),    'A') ||
        setweight(to_tsvector('english', coalesce(category,'')), 'B') ||
        setweight(to_tsvector('english', coalesce(ocr_text,'')), 'C')
    ) STORED;

CREATE INDEX IF NOT EXISTS idx_documents_ocr_tsv
    ON documents USING GIN (ocr_tsv);

-- Allow optional NULL entity_id during upload (linker fills it from the
-- linked entity afterwards).
ALTER TABLE documents ALTER COLUMN entity_id DROP NOT NULL;

-- ---------------------------------------------------------------------------
-- v_documents_linked — convenience view that joins each linked doc to its
-- target row's identifying field for quick display.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_documents_linked AS
SELECT
    d.id,
    d.title,
    d.category,
    d.mime_type,
    d.file_path,
    d.linked_table,
    d.linked_id,
    d.linked_by,
    d.entity_id,
    d.realm,
    d.created_at,
    CASE
      WHEN d.linked_table = 'vehicles' THEN
          (SELECT registration || ' (' || make_model || ')'
             FROM vehicles WHERE id = d.linked_id)
      WHEN d.linked_table = 'properties' THEN
          (SELECT address_line1 FROM properties WHERE id = d.linked_id)
      WHEN d.linked_table = 'children' THEN
          (SELECT name FROM children WHERE id = d.linked_id)
      ELSE NULL
    END AS linked_label
  FROM documents d
 WHERE d.linked_table IS NOT NULL
 ORDER BY d.created_at DESC;

COMMENT ON VIEW v_documents_linked IS
    'Linked-document feed used by /api/documents/by-link/{table}/{id} and '
    'the Mission Control "unlinked docs needing filing" tile.';

COMMIT;
