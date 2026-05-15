-- =============================================================================
-- V81 — Unified search corpus for the /research endpoint (U64)
-- =============================================================================
-- For the MVP we do FTS-based retrieval (no embeddings yet). Three sources:
--   emails.tsv                    — already indexed (V77)
--   vendor_invoice_lines (descr)  — trigram GIN (V41), plus generated tsv here
--   documents.ocr_tsv             — already indexed (V78)
--
-- v_research_corpus is a union view used by /api/research/ask:
--   source_table, source_id, ts (search vector), display_text, realm, entity_id
-- =============================================================================

BEGIN;

-- vendor_invoice_lines needs a search vector for symmetry with emails/documents.
ALTER TABLE vendor_invoice_lines
    ADD COLUMN IF NOT EXISTS search_tsv tsvector
    GENERATED ALWAYS AS (
        to_tsvector('english', coalesce(description, ''))
    ) STORED;

CREATE INDEX IF NOT EXISTS idx_vil_search_tsv
    ON vendor_invoice_lines USING GIN (search_tsv);

CREATE OR REPLACE VIEW v_research_corpus AS
SELECT
    'email'::text     AS source_table,
    e.id              AS source_id,
    e.tsv             AS ts,
    e.subject         AS title,
    e.body_text       AS body,
    e.received_at     AS event_at,
    e.account,
    e.entity_id,
    e.realm
  FROM emails e
 WHERE e.tsv IS NOT NULL

UNION ALL

SELECT
    'invoice_line'    AS source_table,
    vil.id            AS source_id,
    vil.search_tsv    AS ts,
    vil.description   AS title,
    NULL::text        AS body,
    vii.invoice_date::timestamptz AS event_at,
    vii.account,
    vii.entity_id,
    vii.realm
  FROM vendor_invoice_lines vil
  JOIN vendor_invoice_inbox vii ON vii.id = vil.invoice_id

UNION ALL

SELECT
    'document'        AS source_table,
    d.id              AS source_id,
    d.ocr_tsv         AS ts,
    d.title,
    d.ocr_text        AS body,
    d.created_at      AS event_at,
    NULL::text        AS account,
    d.entity_id,
    d.realm
  FROM documents d
 WHERE d.ocr_tsv IS NOT NULL;

COMMENT ON VIEW v_research_corpus IS
    'U64 FTS-based research corpus. Replace with vector-RAG view in U65 once '
    'a real embed model is reachable.';

COMMIT;
