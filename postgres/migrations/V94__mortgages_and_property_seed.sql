-- =============================================================================
-- V94 — Mortgage accounts + property seed (U74)
-- =============================================================================
-- Seeds the four properties Jo confirmed by chat on 2026-05-15:
--   1 Castle Road, PL34 0HE         — entity 3 (Personal)
--   Salutations, PL34 0DE           — entity 3 (Personal)
--   The Olde Malthouse, Tintagel    — entity 3 (Personal); pub building
--   Langholme, PL34 0DD             — entity 2 (Atlantic Road Estates)
--
-- Adds two new tables:
--   mortgage_accounts                 — one row per loan (lender, ref, balance)
--   property_mortgage_accounts        — many-to-many w/ share_pct
--
-- And seeds the first known account:
--   Principality Commercial loan 295905-02
--     borrower:   Atlantic Road Estates Ltd  (entity 2) — common cross-
--                 collateral structure where ARE borrows secured against
--                 personally-owned freeholds.
--     secures:    1 Castle Road  +  Salutations  (50/50 share, adjust later)
--
-- Defaults realm='work' on the loan since mortgage admin sits with the
-- business; properties keep their own realm via entity ownership.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

-- ── Properties seed ─────────────────────────────────────────────────────────
INSERT INTO properties (address_line1, town, postcode, property_type, entity_id, realm)
SELECT * FROM (VALUES
    ('1 Castle Road',      'Tintagel', 'PL34 0HE', 'residential', 3, 'family'),
    ('Salutations',        'Tintagel', 'PL34 0DE', 'residential', 3, 'family'),
    ('The Olde Malthouse', 'Tintagel', NULL,       'commercial',  3, 'family'),
    ('Langholme',          'Tintagel', 'PL34 0DD', 'residential', 2, 'work')
) AS v (address_line1, town, postcode, property_type, entity_id, realm)
WHERE NOT EXISTS (
    SELECT 1 FROM properties p
     WHERE p.address_line1 = v.address_line1
       AND COALESCE(p.postcode, '') = COALESCE(v.postcode, '')
);

-- ── mortgage_accounts ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS mortgage_accounts (
    id                  BIGSERIAL PRIMARY KEY,
    lender              TEXT          NOT NULL,
    account_ref         TEXT          NOT NULL,
    borrower_entity_id  INT           NOT NULL REFERENCES entities(id),
    product_type        TEXT,                                    -- 'commercial', 'residential', 'btl', ...
    opened_date         DATE,
    closed_date         DATE,                                    -- NULL = active
    monthly_payment     NUMERIC(10,2),
    interest_rate       NUMERIC(6,4),                            -- e.g. 0.0875 = 8.75% pa
    current_balance     NUMERIC(12,2),
    balance_as_of       DATE,
    notes               TEXT,
    realm               TEXT          NOT NULL DEFAULT 'work'
                                       CHECK (realm IN ('owner','work','family','shared')),
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    UNIQUE (lender, account_ref)
);

ALTER TABLE mortgage_accounts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS realm_isolation ON mortgage_accounts;
CREATE POLICY realm_isolation ON mortgage_accounts
    USING (CASE
        WHEN COALESCE(current_setting('app.current_realm', true), '') IN ('', 'owner') THEN TRUE
        ELSE realm = current_setting('app.current_realm', true)
    END);

-- ── property_mortgage_accounts (m2m) ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS property_mortgage_accounts (
    property_id          INT           NOT NULL REFERENCES properties(id),
    mortgage_account_id  BIGINT        NOT NULL REFERENCES mortgage_accounts(id) ON DELETE CASCADE,
    share_pct            NUMERIC(5,2)  NOT NULL DEFAULT 100.00
                                        CHECK (share_pct > 0 AND share_pct <= 100),
    realm                TEXT          NOT NULL DEFAULT 'work'
                                        CHECK (realm IN ('owner','work','family','shared')),
    created_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),
    PRIMARY KEY (property_id, mortgage_account_id)
);

ALTER TABLE property_mortgage_accounts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS realm_isolation ON property_mortgage_accounts;
CREATE POLICY realm_isolation ON property_mortgage_accounts
    USING (CASE
        WHEN COALESCE(current_setting('app.current_realm', true), '') IN ('', 'owner') THEN TRUE
        ELSE realm = current_setting('app.current_realm', true)
    END);

-- Grants (homeai_pipeline role used by AI services).
GRANT SELECT, INSERT, UPDATE ON mortgage_accounts, property_mortgage_accounts TO homeai_pipeline;
GRANT USAGE, SELECT ON mortgage_accounts_id_seq TO homeai_pipeline;

-- ── Seed Principality 295905-02 ─────────────────────────────────────────────
INSERT INTO mortgage_accounts
    (lender, account_ref, borrower_entity_id, product_type,
     monthly_payment, current_balance, balance_as_of, notes, realm)
SELECT 'Principality Commercial', '295905-02', 2, 'commercial',
       2288.92, 180204.46, '2025-01-01',
       'Cross-collateral: ARE is borrower; freeholds owned by Jo personally. '
       'Balance + monthly payment seeded from Q1-2025 statement (doc 19). '
       'Re-extract on each new statement scan.',
       'work'
WHERE NOT EXISTS (
    SELECT 1 FROM mortgage_accounts
     WHERE lender='Principality Commercial' AND account_ref='295905-02'
);

-- Link Castle Road + Salutations to the loan at 50/50.
INSERT INTO property_mortgage_accounts (property_id, mortgage_account_id, share_pct, realm)
SELECT p.id, m.id, 50.00, 'work'
  FROM properties p
  JOIN mortgage_accounts m
    ON m.lender='Principality Commercial' AND m.account_ref='295905-02'
 WHERE p.address_line1 IN ('1 Castle Road', 'Salutations')
   AND p.town = 'Tintagel'
   AND NOT EXISTS (
       SELECT 1 FROM property_mortgage_accounts pma
        WHERE pma.property_id = p.id AND pma.mortgage_account_id = m.id
   );

-- Backlink the scanned statement (documents.id=19) to the mortgage account.
UPDATE documents d
   SET linked_table = 'mortgage_accounts',
       linked_id    = (SELECT id FROM mortgage_accounts
                        WHERE lender='Principality Commercial'
                          AND account_ref='295905-02'),
       linked_by    = 'auto:loan-num-match',
       category     = 'mortgage_statement'
 WHERE d.id = 19
   AND (d.linked_table IS NULL OR d.linked_by LIKE 'auto:%');

COMMIT;
