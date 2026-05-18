-- =============================================================================
-- V107 — U68: doc auto-classifier expansion
-- =============================================================================
-- 1. entities.utr + entities.vat_number   — for HMRC linker
-- 2. property_utilities                    — utility account # ↔ property
-- 3. documents_classification_queue        — Haiku fall-through queue
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. entities — UTR + VAT for HMRC document linker
-- ---------------------------------------------------------------------------

ALTER TABLE entities
    ADD COLUMN IF NOT EXISTS utr TEXT,        -- 10-digit Unique Taxpayer Reference
    ADD COLUMN IF NOT EXISTS vat_number TEXT; -- e.g. GB123456789

CREATE INDEX IF NOT EXISTS idx_entities_utr ON entities (utr) WHERE utr IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_entities_vat ON entities (vat_number) WHERE vat_number IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. property_utilities — utility account # ↔ property (for bill auto-link)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS property_utilities (
    id             BIGSERIAL PRIMARY KEY,
    property_id    INTEGER     NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
    utility_kind   TEXT        NOT NULL,    -- 'electricity'|'gas'|'water'|'broadband'|'council_tax'|'oil'
    provider       TEXT,                    -- 'British Gas','Octopus','EDF','South West Water', etc.
    account_number TEXT,                    -- the customer ref
    mpan_or_mprn   TEXT,                    -- electricity MPAN, gas MPRN if known
    realm          TEXT        NOT NULL DEFAULT 'family',
    notes          TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (property_id, utility_kind, provider)
);

ALTER TABLE property_utilities DROP CONSTRAINT IF EXISTS property_utilities_kind_check;
ALTER TABLE property_utilities ADD CONSTRAINT property_utilities_kind_check
    CHECK (utility_kind IN ('electricity','gas','water','broadband','council_tax','oil','phone','other'));

ALTER TABLE property_utilities DROP CONSTRAINT IF EXISTS property_utilities_realm_check;
ALTER TABLE property_utilities ADD CONSTRAINT property_utilities_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

CREATE INDEX IF NOT EXISTS idx_prop_utilities_account
    ON property_utilities (account_number) WHERE account_number IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_prop_utilities_mpan
    ON property_utilities (mpan_or_mprn) WHERE mpan_or_mprn IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_prop_utilities_provider_trgm
    ON property_utilities USING gin (provider gin_trgm_ops);

-- ---------------------------------------------------------------------------
-- 3. documents_classification_queue — pending Haiku classification
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS documents_classification_queue (
    id               BIGSERIAL PRIMARY KEY,
    document_id      BIGINT      NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    status           TEXT        NOT NULL DEFAULT 'pending',
    -- Layer 3 Haiku output:
    suggested_doc_type   TEXT,                    -- 'mot|mortgage_statement|water_bill|...'
    suggested_link_table TEXT,                    -- 'vehicles|properties|bank_accounts|...'
    suggested_link_id    INTEGER,                 -- best-guess FK
    suggested_link_hint  TEXT,                    -- e.g. plate/postcode/account-#
    confidence           NUMERIC(4,3),
    summary              TEXT,                    -- 1-line model-written summary
    model_used           TEXT,                    -- 'haiku-4-5','sonnet-4-6','manual'
    review_resolution    TEXT,                    -- 'auto_accepted'|'manual_confirmed'|'rejected'
    reviewed_by          TEXT,
    reviewed_at          TIMESTAMPTZ,
    classified_at        TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (document_id)
);

ALTER TABLE documents_classification_queue
    DROP CONSTRAINT IF EXISTS doc_clq_status_check;
ALTER TABLE documents_classification_queue
    ADD CONSTRAINT doc_clq_status_check
    CHECK (status IN ('pending','classified','needs_review','auto_applied','manual_applied','rejected'));

CREATE INDEX IF NOT EXISTS idx_doc_clq_status
    ON documents_classification_queue (status, created_at DESC);

-- ---------------------------------------------------------------------------
-- 4. Helper view — what currently needs review
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_documents_needing_review AS
SELECT
    d.id                       AS document_id,
    d.title,
    d.category,
    d.created_at,
    d.linked_table,
    d.linked_id,
    d.linked_by,
    d.uploaded_by,
    d.realm,
    LENGTH(coalesce(d.ocr_text,'')) AS ocr_chars,
    q.id                       AS queue_id,
    q.status                   AS classifier_status,
    q.suggested_doc_type,
    q.suggested_link_table,
    q.suggested_link_id,
    q.suggested_link_hint,
    q.confidence,
    q.summary
  FROM documents d
  LEFT JOIN documents_classification_queue q ON q.document_id = d.id
 WHERE d.linked_table IS NULL
    OR (q.confidence IS NOT NULL AND q.confidence < 0.85
        AND COALESCE(q.review_resolution, '') = '')
 ORDER BY d.created_at DESC;

COMMENT ON VIEW v_documents_needing_review IS
    'U68 — drives /documents review-queue chip. Unlinked docs + low-confidence '
    'classifier outputs that need Jo''s eye.';

COMMIT;
