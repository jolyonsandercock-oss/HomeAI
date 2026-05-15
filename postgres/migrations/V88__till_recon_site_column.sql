-- =============================================================================
-- V88 — till_reconciliation.site (U71 T1)
-- =============================================================================
-- The mobile cashing-up form (/m) lets staff record till counts per site.
-- Existing rows are back-filled to 'pub' since that's where every legacy
-- z_reading came from. CHECK constraint allows pub/cafe/other so we don't
-- need a follow-up migration if Jo opens a third site.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

ALTER TABLE till_reconciliation
    ADD COLUMN IF NOT EXISTS site TEXT NOT NULL DEFAULT 'pub';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.check_constraints
         WHERE constraint_schema = 'public'
           AND constraint_name = 'till_reconciliation_site_check'
    ) THEN
        ALTER TABLE till_reconciliation
            ADD CONSTRAINT till_reconciliation_site_check
            CHECK (site IN ('pub', 'cafe', 'other'));
    END IF;
END$$;

CREATE INDEX IF NOT EXISTS idx_till_recon_date_site
    ON till_reconciliation (recon_date DESC, site);

COMMIT;
