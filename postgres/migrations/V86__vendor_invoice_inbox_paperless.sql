-- =============================================================================
-- V86 — vendor_invoice_inbox: add columns needed by Paperless ingest (U70 T2)
-- =============================================================================
-- The /api/documents/ingest-from-paperless endpoint inserts into
-- vendor_invoice_inbox for invoice-typed Paperless documents so the existing
-- Haiku line-extractor picks them up automatically.
--
-- New columns:
--   body_text         — OCR'd text from Paperless (analogous to email body)
--   pipeline_version  — provenance tag ('paperless:u70', 'gmail-poller:1.3', …)
--   paperless_doc_id  — back-pointer to documents.paperless_id for trace
--   sort_key          — for /invoices ordering when received_at is NULL
-- =============================================================================

BEGIN;

ALTER TABLE vendor_invoice_inbox
    ADD COLUMN IF NOT EXISTS body_text         TEXT,
    ADD COLUMN IF NOT EXISTS pipeline_version  TEXT,
    ADD COLUMN IF NOT EXISTS paperless_doc_id  BIGINT;

CREATE INDEX IF NOT EXISTS idx_vii_paperless ON vendor_invoice_inbox (paperless_doc_id) WHERE paperless_doc_id IS NOT NULL;

COMMIT;
