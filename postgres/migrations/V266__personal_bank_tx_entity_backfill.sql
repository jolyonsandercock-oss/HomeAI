-- =============================================================================
-- V266 — backfill NULL entity_id on personal-realm bank_transactions
-- =============================================================================
-- Completes V260 (which fixed the 2,286 work-realm rows and deferred these).
-- The canonical mapping needs no human call: bank_accounts already carries
-- entity_id for all five accounts, and every row's realm already equals
-- realm_from_entity_id(entity) — verified 2026-06-11:
--   acct  6  SANDERCOCK J main personal current → entity 3   8,616 rows
--   acct  7  SANDERCOCK J personal #2           → entity 3      88 rows
--   acct  8  SANDERCOCK J personal #3           → entity 3      22 rows
--   acct  9  SANDERCOCK J personal #4           → entity 3      65 rows
--   acct 10  Joint Account                      → entity 4      43 rows
-- PERMISSIVE entity RLS silently hides NULL-entity rows from entity-scoped
-- queries — same defect class as V260. Forward inserts already guarded by
-- trg_bank_transactions_entity (V260). Realm: personal (existing row realms
-- unchanged; RLS gates per-row).
-- =============================================================================

BEGIN;

-- ── preconditions (compute-and-assert) ──────────────────────────────────────
DO $$
DECLARE c6 int; c7 int; c8 int; c9 int; c10 int; tot int; bad int; oth int;
BEGIN
    SELECT count(*) INTO c6  FROM bank_transactions WHERE bank_account_id=6  AND entity_id IS NULL;
    SELECT count(*) INTO c7  FROM bank_transactions WHERE bank_account_id=7  AND entity_id IS NULL;
    SELECT count(*) INTO c8  FROM bank_transactions WHERE bank_account_id=8  AND entity_id IS NULL;
    SELECT count(*) INTO c9  FROM bank_transactions WHERE bank_account_id=9  AND entity_id IS NULL;
    SELECT count(*) INTO c10 FROM bank_transactions WHERE bank_account_id=10 AND entity_id IS NULL;
    SELECT count(*) INTO tot FROM bank_transactions WHERE entity_id IS NULL;
    IF (c6,c7,c8,c9,c10) IS DISTINCT FROM (8616,88,22,65,43) OR tot <> c6+c7+c8+c9+c10 THEN
        RAISE EXCEPTION 'V266 precondition drifted: a6=%, a7=%, a8=%, a9=%, a10=%, total_null=% (expected 8616/88/22/65/43, no others) — re-derive before applying',
            c6,c7,c8,c9,c10,tot;
    END IF;
    -- every NULL row's realm must already equal the canonical realm of its account's entity
    SELECT count(*) INTO bad FROM bank_transactions bt
      JOIN bank_accounts ba ON ba.id=bt.bank_account_id
     WHERE bt.entity_id IS NULL
       AND bt.realm <> realm_from_entity_id(ba.entity_id);
    IF bad <> 0 THEN
        RAISE EXCEPTION 'V266 precondition: % rows would contradict realm_from_entity_id', bad;
    END IF;
    -- the five accounts must actually carry the expected entities
    SELECT count(*) INTO oth FROM bank_accounts
     WHERE (id IN (6,7,8,9) AND entity_id IS DISTINCT FROM 3)
        OR (id = 10 AND entity_id IS DISTINCT FROM 4);
    IF oth <> 0 THEN
        RAISE EXCEPTION 'V266 precondition: bank_accounts entity mapping changed (% mismatches)', oth;
    END IF;
END $$;

-- ── backfill from the canonical account registry ────────────────────────────
UPDATE bank_transactions bt
   SET entity_id = ba.entity_id
  FROM bank_accounts ba
 WHERE ba.id = bt.bank_account_id
   AND bt.entity_id IS NULL;

INSERT INTO audit_log (pipeline, action, record_type, ai_parsed, result, realm)
VALUES ('U250', 'personal_entity_backfill', 'bank_transactions',
        jsonb_build_object('rows', 8834,
            'mapping', 'accts 6-9 -> entity 3, acct 10 -> entity 4 (from bank_accounts)',
            'reason', 'NULL entity_id invisible under PERMISSIVE entity RLS; completes V260',
            'actor', 'V266'),
        'success', 'owner');

-- ── postconditions ───────────────────────────────────────────────────────────
DO $$
DECLARE n int; bad int; tot int;
BEGIN
    SELECT count(*) INTO n FROM bank_transactions WHERE entity_id IS NULL;
    IF n <> 0 THEN
        RAISE EXCEPTION 'V266 postcondition: % NULL entity_id rows remain', n;
    END IF;
    SELECT count(*) INTO bad FROM bank_transactions
     WHERE realm <> realm_from_entity_id(entity_id);
    IF bad <> 0 THEN
        RAISE EXCEPTION 'V266 postcondition: % realm/entity inconsistencies', bad;
    END IF;
    SELECT count(*) INTO tot FROM bank_transactions;
    IF tot <> 22476 THEN
        RAISE EXCEPTION 'V266 postcondition: row count changed (% vs 22476)', tot;
    END IF;
    RAISE NOTICE 'V266: all bank_transactions now entity-attributed, realm-consistent';
END $$;

COMMIT;
