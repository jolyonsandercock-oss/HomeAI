-- =============================================================================
-- V66 — query_whitelist realm seeding + realm_not_allowed rejection reason
-- =============================================================================
-- query_whitelist.realm and query_rejections.realm columns already exist
-- (added in V64). This migration:
--   * Re-seeds query_whitelist.realm per-row by query intent (was all 'owner').
--   * Extends query_rejections.reason check constraint with 'realm_not_allowed'.
--
-- Single-realm model (not allowed_realms[]): each query belongs to ONE realm.
-- Caller can run it iff caller_realm = row.realm OR row.realm = 'shared' OR
-- caller_realm = 'owner'. This matches the bot_sender_whitelist column shape
-- and avoids array operators in the slug-load query.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Step 1: Reseed per-slug realms by intent.
-- -----------------------------------------------------------------------------

UPDATE query_whitelist SET realm = 'work'
 WHERE slug IN ('last_7d_unit_economics','latest_caterbook_occupancy','today_totals');

UPDATE query_whitelist SET realm = 'owner'
 WHERE slug IN ('pending_invoices','entity_summary','recent_alerts');

-- -----------------------------------------------------------------------------
-- Step 2: Extend query_rejections.reason check to include 'realm_not_allowed'.
-- -----------------------------------------------------------------------------

ALTER TABLE query_rejections DROP CONSTRAINT IF EXISTS query_rejections_reason_check;
ALTER TABLE query_rejections ADD CONSTRAINT query_rejections_reason_check
    CHECK (reason = ANY (ARRAY[
        'no_slug','unknown_slug','inactive_slug','unapproved_slug',
        'param_missing','param_type','param_range',
        'rls_block','realm_not_allowed','runtime_error','other'
    ]));

-- -----------------------------------------------------------------------------
-- Verification
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    work_count INT;
    owner_count INT;
BEGIN
    SELECT COUNT(*) INTO work_count FROM query_whitelist WHERE realm = 'work';
    SELECT COUNT(*) INTO owner_count FROM query_whitelist WHERE realm = 'owner';
    IF work_count + owner_count = 0 THEN
        RAISE EXCEPTION 'V66 verification failed: no realm reseeding took effect';
    END IF;
    RAISE NOTICE 'V66 verification PASS: % work / % owner query_whitelist rows.', work_count, owner_count;
END $$;

COMMIT;
