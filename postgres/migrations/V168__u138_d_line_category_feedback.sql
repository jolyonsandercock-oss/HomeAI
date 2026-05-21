-- =============================================================================
-- V168 — U138 Phase D-ii: line_category_feedback for AI training surface.
-- =============================================================================
-- Captures user corrections of line-item categorisation. Three kinds of
-- correction supported in one row:
--   * corrected_department — bar/kitchen/rooms/cafe/overhead
--   * corrected_family     — product family text (no FK; mirrors product_canonical.family)
--   * corrected_canonical_id — full canonical product reference
--
-- vendor_domain + description_lower are DENORMALISED at write time so
-- pattern queries (similar lines from same vendor) don't have to join.
--
-- Nightly script scripts/u138-promote-feedback-to-rules.py reads this and
-- promotes ≥3-agreement vendor+desc clusters to vendor_category_rules.
-- =============================================================================

BEGIN;

CREATE TABLE line_category_feedback (
    id                     bigserial PRIMARY KEY,
    line_id                bigint  NOT NULL REFERENCES vendor_invoice_lines(id) ON DELETE CASCADE,
    invoice_id             bigint  NOT NULL,
    vendor_domain          text    NOT NULL,
    description_raw        text    NOT NULL,
    description_lower      text    GENERATED ALWAYS AS (lower(description_raw)) STORED,
    corrected_department   text    CHECK (corrected_department IS NULL
                                          OR corrected_department IN ('bar','kitchen','rooms','cafe','overhead')),
    corrected_family       text,
    corrected_canonical_id bigint  REFERENCES product_canonical(id),
    corrected_category     text,                          -- email-level category override (rare)
    source                 text    NOT NULL DEFAULT 'manual'
                                   CHECK (source IN ('manual','nightly_haiku','rule_match','xero_sync')),
    confidence             numeric(3,2),
    corrected_by           text    NOT NULL,
    corrected_at           timestamptz NOT NULL DEFAULT NOW(),
    realm                  text    NOT NULL DEFAULT 'shared'
                                   CHECK (realm IN ('owner','work','personal','family','shared'))
);

CREATE INDEX idx_lcf_vendor          ON line_category_feedback(vendor_domain);
CREATE INDEX idx_lcf_desc_trgm       ON line_category_feedback USING gin (description_lower gin_trgm_ops);
CREATE INDEX idx_lcf_line            ON line_category_feedback(line_id);
CREATE INDEX idx_lcf_corrected_at    ON line_category_feedback(corrected_at DESC);

ALTER TABLE line_category_feedback ENABLE ROW LEVEL SECURITY;

-- Mirror the realm_isolation policy shape used elsewhere (post-V164 widened).
CREATE POLICY realm_isolation ON line_category_feedback
USING (
  CASE
    WHEN current_setting('app.current_realm', true) = 'owner'    THEN TRUE
    WHEN current_setting('app.current_realm', true) = 'work'     THEN (realm = ANY (ARRAY['work','shared']))
    WHEN current_setting('app.current_realm', true) = 'personal' THEN (realm = ANY (ARRAY['family','personal','shared']))
    WHEN current_setting('app.current_realm', true) = 'family'   THEN (realm = ANY (ARRAY['family','personal','shared']))
    WHEN (current_setting('app.current_realm', true) IS NULL
       OR current_setting('app.current_realm', true) = '')       THEN TRUE
    ELSE FALSE
  END
);

-- ---------- slug: recent feedback for the admin tile ------------------------
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, result_format,
   active, created_by, approved_at, approved_by, notes, realm, intent_examples)
VALUES
('line_feedback_recent',
 'U138 — recent line categorisation feedback',
 'Most recent N corrections to line categorisation. Used by /admin/invoices/[id] sidebar and by the nightly promoter as input.',
 $sql$SELECT id, line_id, invoice_id, vendor_domain,
              description_raw,
              corrected_department, corrected_family, corrected_canonical_id,
              source, confidence, corrected_by, corrected_at
         FROM line_category_feedback
        ORDER BY corrected_at DESC
        LIMIT COALESCE(:limit::int, 50)$sql$,
 '{"limit":{"type":"int","optional":true}}'::jsonb,
 'table', true, 'u138', NOW(), 'u138', NULL, 'shared',
 ARRAY['recent feedback','line corrections']);

COMMIT;
