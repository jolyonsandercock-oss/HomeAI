-- =============================================================================
-- V184 — U161: auto-vision-OCR on image-only PDFs
-- =============================================================================
-- documents gains needs_vision_ocr flag; vision_ocr_jobs queue table tracks
-- per-doc OCR runs so the worker can be idempotent and replay-safe.
-- =============================================================================

BEGIN;

ALTER TABLE documents
  ADD COLUMN IF NOT EXISTS needs_vision_ocr BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS vision_ocr_done  BOOLEAN DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_documents_needs_vision_ocr
  ON documents (needs_vision_ocr)
  WHERE needs_vision_ocr = true AND vision_ocr_done = false;

CREATE TABLE IF NOT EXISTS vision_ocr_jobs (
  id            BIGSERIAL PRIMARY KEY,
  document_id   BIGINT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  paperless_id  INTEGER,
  status        TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','running','done','failed','skipped')),
  attempts      INTEGER NOT NULL DEFAULT 0,
  pages         INTEGER,
  periods_added INTEGER,
  cost_gbp      NUMERIC(10,4),
  error_msg     TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  started_at    TIMESTAMPTZ,
  completed_at  TIMESTAMPTZ,
  realm         TEXT NOT NULL DEFAULT 'owner'
                  CHECK (realm IN ('owner','work','personal','shared')),
  UNIQUE (document_id)
);

CREATE INDEX IF NOT EXISTS idx_vision_ocr_jobs_pending
  ON vision_ocr_jobs (status, created_at)
  WHERE status = 'pending';

-- Backfill: mark known image-only PDFs from U151b run as 'done'
INSERT INTO vision_ocr_jobs (document_id, paperless_id, status, completed_at, periods_added)
SELECT id, paperless_id, 'done', NOW(), 1
  FROM documents
 WHERE paperless_id IN (12,13,14,15,16,17,18)
ON CONFLICT (document_id) DO NOTHING;

UPDATE documents SET needs_vision_ocr=true, vision_ocr_done=true
 WHERE paperless_id IN (12,13,14,15,16,17,18);

-- Slug to surface queue depth
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'vision_ocr_queue_status',
  'Vision-OCR queue status',
  'U161: image-only PDF re-OCR queue. Surfaces backlog + recent failures.',
  E'SELECT status, count(*) AS jobs,
           max(created_at) AS latest,
           sum(COALESCE(periods_added,0)) AS total_periods_added
      FROM vision_ocr_jobs
     GROUP BY status ORDER BY status',
  '{}', 'shared', true, NOW(), 'u161', 'u161'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

COMMIT;
