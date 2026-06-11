-- =============================================================================
-- V260 — U250 P1: backfill NULL entity_id on work-realm bank_transactions
-- =============================================================================
-- Finding (2026-06-10 review): 2,286 work-realm rows have entity_id IS NULL
-- across 4 accounts. entity_isolation RLS is PERMISSIVE, so NULL-entity rows
-- silently vanish from entity-scoped queries.
--
-- Mapping (canonical source = bank_accounts, verified 2026-06-10):
--   acct  3  ATR Trading current        → entity 1 (work)        82 rows
--   acct  4  Tax Reserve ATR savings    → entity 1 (work)         6 rows
--   acct 16  Cap On Tap business card   → entity 1 (work)     1,456 rows
--            (bank_accounts.entity_id itself NULL — fixed here too; evidence
--             storage/TRANSFERS-ANALYSIS.md: "ATR Trading → ATR Credit Card
--             (Cap On Tap)")
--   acct  5  AREL current               → entity 2            742 rows
--            BUT these rows carry realm='work' hardcoded by the statement
--            importers — wrong since the V164 ARE→PERSONAL pivot
--            (bank_accounts.realm='personal', realm_from_entity_id(2)=
--            'personal'). Flipped to 'personal' here via the V164
--            realm_override_active pattern, so the global invariant
--            realm = realm_from_entity_id(entity_id) keeps holding (it holds
--            for 0 violations today among non-NULL rows).
--
-- Personal-realm NULLs (8,834 rows, accts 6-10) are intentionally NOT touched:
-- diagnosis + proposal documented in the U250 sprint doc; awaiting Jo.
--
-- Forward guard: BEFORE INSERT trigger derives entity_id from bank_accounts
-- when the importer doesn't supply one. Named to sort alphabetically BEFORE
-- trg_bank_transactions_realm so realm derivation sees the filled entity_id.
-- Realm: work (ATR-side financial plumbing; rows span work+personal realms,
-- gated per-row by existing RLS).
-- =============================================================================

BEGIN;

-- ── preconditions (compute-and-assert) ──────────────────────────────────────
DO $$
DECLARE c3 int; c4 int; c5 int; c16 int; cw int; bad int;
BEGIN
    SELECT count(*) INTO cw  FROM bank_transactions WHERE realm='work' AND entity_id IS NULL;
    SELECT count(*) INTO c3  FROM bank_transactions WHERE bank_account_id=3  AND entity_id IS NULL;
    SELECT count(*) INTO c4  FROM bank_transactions WHERE bank_account_id=4  AND entity_id IS NULL;
    SELECT count(*) INTO c5  FROM bank_transactions WHERE bank_account_id=5  AND entity_id IS NULL;
    SELECT count(*) INTO c16 FROM bank_transactions WHERE bank_account_id=16 AND entity_id IS NULL;
    IF (cw, c3, c4, c5, c16) IS DISTINCT FROM (2286, 82, 6, 742, 1456) THEN
        RAISE EXCEPTION 'V260 precondition drifted: work_null=%, a3=%, a4=%, a5=%, a16=% (expected 2286/82/6/742/1456) — re-derive counts before applying', cw, c3, c4, c5, c16;
    END IF;
    SELECT count(*) INTO bad FROM bank_transactions
     WHERE entity_id IS NOT NULL AND realm <> realm_from_entity_id(entity_id);
    IF bad <> 0 THEN
        RAISE EXCEPTION 'V260 precondition: % pre-existing realm/entity inconsistencies', bad;
    END IF;
END $$;

-- ── 1. bank_accounts: Cap On Tap is ATR Trading's card ──────────────────────
UPDATE bank_accounts SET entity_id = 1 WHERE id = 16 AND entity_id IS NULL;

-- ── 2. accts 3, 4, 16 → entity 1 (realm 'work' already correct) ─────────────
UPDATE bank_transactions SET entity_id = 1
 WHERE bank_account_id IN (3, 4, 16) AND entity_id IS NULL;

-- ── 3. acct 5 (AREL) → entity 2 + realm work→personal ───────────────────────
SELECT set_config('app.realm_override_active', '1', true);
UPDATE bank_transactions SET entity_id = 2, realm = 'personal'
 WHERE bank_account_id = 5 AND entity_id IS NULL;
SELECT set_config('app.realm_override_active', '', true);

INSERT INTO audit_log (pipeline, action, record_type, record_id, ai_parsed, result, realm)
VALUES ('U250', 'realm_override_bulk', 'bank_transactions', 5,
        jsonb_build_object(
            'scope',     'bank_account_id=5 AND entity_id IS NULL',
            'rows',      742,
            'old_realm', 'work',
            'new_realm', 'personal',
            'reason',    'AREL rows imported with hardcoded realm=work; canonical realm is personal (V164 ARE pivot, bank_accounts.realm, realm_from_entity_id(2))',
            'actor',     'U250 V260'),
        'success', 'owner');

-- ── postconditions (compute-and-assert) ─────────────────────────────────────
DO $$
DECLARE cw int; bad int; a5w int; tot int;
BEGIN
    SELECT count(*) INTO cw FROM bank_transactions WHERE realm='work' AND entity_id IS NULL;
    IF cw <> 0 THEN
        RAISE EXCEPTION 'V260 postcondition: % work-realm NULL entity_id rows remain', cw;
    END IF;
    SELECT count(*) INTO a5w FROM bank_transactions WHERE bank_account_id=5 AND realm='work';
    IF a5w <> 0 THEN
        RAISE EXCEPTION 'V260 postcondition: % acct-5 rows still realm=work', a5w;
    END IF;
    SELECT count(*) INTO bad FROM bank_transactions
     WHERE entity_id IS NOT NULL AND realm <> realm_from_entity_id(entity_id);
    IF bad <> 0 THEN
        RAISE EXCEPTION 'V260 postcondition: % realm/entity inconsistencies introduced', bad;
    END IF;
    SELECT count(*) INTO tot FROM bank_transactions;
    IF tot <> 22476 THEN
        RAISE EXCEPTION 'V260 postcondition: row count changed (% vs 22476) — UPDATE must not add/remove rows', tot;
    END IF;
END $$;

-- ── 4. forward guard: derive entity_id from bank_accounts on INSERT ─────────
CREATE OR REPLACE FUNCTION trg_bank_tx_entity_from_account()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.entity_id IS NULL AND NEW.bank_account_id IS NOT NULL THEN
        SELECT entity_id INTO NEW.entity_id
          FROM bank_accounts WHERE id = NEW.bank_account_id;
    END IF;
    RETURN NEW;
END $$;

-- "...entity" < "...realm" alphabetically → fires first, so the realm trigger
-- derives realm from the freshly-filled entity_id when realm comes in NULL.
DROP TRIGGER IF EXISTS trg_bank_transactions_entity ON bank_transactions;
CREATE TRIGGER trg_bank_transactions_entity
    BEFORE INSERT ON bank_transactions
    FOR EACH ROW EXECUTE FUNCTION trg_bank_tx_entity_from_account();

COMMIT;
