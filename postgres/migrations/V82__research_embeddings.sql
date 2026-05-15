-- =============================================================================
-- V82 — Vector embeddings for /research (PART 4b carry-forward from U64)
-- =============================================================================
-- Stores qwen2.5:7b embeddings (3584-dim) for every row in v_research_corpus.
--
-- We skip pgvector to avoid an extension install on the running cluster.
-- Embeddings live as REAL[] (PG native float4[]); cosine similarity is
-- computed in Python at query time (1,211 items × 3584 floats = ~17MB read,
-- ~50ms in numpy). When pgvector lands, migration is a single ALTER+COPY.
--
-- The (source_kind, source_id) natural key matches v_research_corpus exactly
-- so the embed builder can `LEFT JOIN ... WHERE search_vectors.id IS NULL`
-- and incrementally fill new corpus items.
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS search_vectors (
    id              BIGSERIAL PRIMARY KEY,
    source_kind     TEXT        NOT NULL,    -- 'email' | 'invoice_line' | 'document'
    source_id       BIGINT      NOT NULL,
    model           TEXT        NOT NULL DEFAULT 'qwen2.5:7b',
    dim             INTEGER     NOT NULL,
    embedding       REAL[]      NOT NULL,
    text_snippet    TEXT        NOT NULL,    -- the text fed to the model (for audit)
    computed_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    realm           TEXT        NOT NULL DEFAULT 'owner'
                                  CHECK (realm IN ('owner','work','family','shared')),
    UNIQUE (source_kind, source_id, model)
);

CREATE INDEX IF NOT EXISTS idx_search_vectors_kind_id
    ON search_vectors (source_kind, source_id);

COMMENT ON TABLE search_vectors IS
    'V82: dense embeddings for the v_research_corpus. Python-side cosine '
    'until pgvector is installed. One row per (source_kind, source_id, model).';

COMMIT;
