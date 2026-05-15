-- =============================================================================
-- V77 — Full-text search on emails (U61 T3)
-- =============================================================================
-- Adds a STORED tsvector + GIN index. Subject gets weight A, sender weight B,
-- body weight C. Lets the /search page hit a single mailbox-wide query and
-- highlight matches with ts_headline.
-- =============================================================================

BEGIN;

ALTER TABLE emails
    ADD COLUMN IF NOT EXISTS tsv tsvector
    GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(subject,'')),      'A') ||
        setweight(to_tsvector('english', coalesce(from_name,'')),    'B') ||
        setweight(to_tsvector('english', coalesce(from_address,'')), 'B') ||
        setweight(to_tsvector('english', coalesce(body_text,'')),    'C')
    ) STORED;

CREATE INDEX IF NOT EXISTS idx_emails_tsv ON emails USING GIN (tsv);

-- Trigram on subject + body for fuzzy matches (sort codes, account numbers,
-- partial strings to_tsquery would miss).
CREATE INDEX IF NOT EXISTS idx_emails_subject_trgm
    ON emails USING GIN (subject gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_emails_body_trgm
    ON emails USING GIN (body_text gin_trgm_ops);

-- Sanity check
DO $$
DECLARE
    n INT;
BEGIN
    SELECT COUNT(*) INTO n FROM emails WHERE tsv IS NOT NULL;
    RAISE NOTICE 'V77: % emails now have populated tsv', n;
END $$;

COMMIT;
