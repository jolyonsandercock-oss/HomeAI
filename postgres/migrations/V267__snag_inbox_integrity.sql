-- =============================================================================
-- V267 — snag_inbox closure integrity
-- =============================================================================
-- Audit finding (2026-06-11): 60 of 68 'done' snags had NO resolved_at and no
-- notes — statuses were bulk-flipped with no resolution evidence, and several
-- were provably not done (weather, reviews, invoice links, cornish bakery).
-- Enforce: closing a snag (done/accepted/ignored) REQUIRES non-empty notes
-- saying what was actually done, and resolved_at is stamped automatically.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.snag_inbox_closure_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status IN ('done','accepted','ignored')
       AND COALESCE(OLD.status,'') IS DISTINCT FROM NEW.status THEN
        IF length(trim(COALESCE(NEW.notes,''))) < 10 THEN
            RAISE EXCEPTION 'snag %: closing as % requires notes (>=10 chars) describing what was done/decided',
                COALESCE(NEW.id, 0), NEW.status;
        END IF;
        NEW.resolved_at := COALESCE(NEW.resolved_at, now());
    END IF;
    -- reopening clears resolution stamp
    IF NEW.status = 'pending' AND OLD.status IN ('done','accepted','ignored') THEN
        NEW.resolved_at := NULL;
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_snag_inbox_closure ON snag_inbox;
CREATE TRIGGER trg_snag_inbox_closure
    BEFORE UPDATE ON snag_inbox
    FOR EACH ROW EXECUTE FUNCTION public.snag_inbox_closure_guard();

-- backfill resolved_at for already-done rows so reporting is consistent
UPDATE snag_inbox SET resolved_at = COALESCE(resolved_at, updated_at)
 WHERE status IN ('done','accepted','ignored') AND resolved_at IS NULL;

-- assertions
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM snag_inbox WHERE status IN ('done','accepted','ignored') AND resolved_at IS NULL;
    IF n <> 0 THEN RAISE EXCEPTION 'V267: % closed snags still missing resolved_at', n; END IF;
    -- guard works: closing without notes must fail
    BEGIN
        UPDATE snag_inbox SET status='pending', notes=NULL WHERE id=(SELECT min(id) FROM snag_inbox);
        UPDATE snag_inbox SET status='done' WHERE id=(SELECT min(id) FROM snag_inbox);
        RAISE EXCEPTION 'V267: closure guard did NOT fire';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE '%closure guard did NOT fire%' THEN RAISE; END IF;
        -- expected rejection — restore the test row
        UPDATE snag_inbox SET status='done', notes='V267 self-test row (test snag #1, dark-mode toggle): restored after guard verification.'
         WHERE id=(SELECT min(id) FROM snag_inbox);
    END;
END $$;

COMMIT;
