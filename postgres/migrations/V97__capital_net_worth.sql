-- =============================================================================
-- V97 — Capital position + net worth (U77)
-- =============================================================================
-- Jo confirmed by chat on 2026-05-15:
--   1 Castle Road   £600,000
--   2 Salutations   £220,000  ← split out from existing "Salutations" row
--   3 Salutations   £275,000  ← new row at the same Salutations postcode
--   Langholme       £500,000
--   Malthouse       £600,000
--
-- Mortgage 295905-02 covers all three of (1 Castle Rd, 2 Saluts, 3 Saluts).
-- Re-weight share_pct by current_value so the per-property exposure reflects
-- the actual security on each freehold:
--   Castle  600/1095 = 54.79%
--   2 Sal   220/1095 = 20.09%
--   3 Sal   275/1095 = 25.12%
--
-- Adds:
--   v_mortgage_summary (refreshed)        — also includes closed_date
--   v_capital_summary                     — properties + values + mortgage on each
--   v_net_worth_summary                   — single-row KPI: assets/liab/net
--   query_whitelist rows: capital_summary, net_worth_summary, mortgages_all
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

-- ── Property values + Salutations split ─────────────────────────────────────
-- Rename the existing "Salutations" row to "2 Salutations".
UPDATE properties SET address_line1 = '2 Salutations', current_value = 220000.00
 WHERE address_line1 = 'Salutations' AND town = 'Tintagel';

-- Add "3 Salutations" if not already present.
INSERT INTO properties (address_line1, town, postcode, property_type, entity_id, current_value, realm)
SELECT '3 Salutations', 'Tintagel', 'PL34 0DE', 'residential', 3, 275000.00, 'family'
WHERE NOT EXISTS (
    SELECT 1 FROM properties WHERE address_line1='3 Salutations' AND town='Tintagel'
);

-- Set current_value on the other three known properties.
UPDATE properties SET current_value = 600000.00 WHERE address_line1='1 Castle Road'      AND town='Tintagel';
UPDATE properties SET current_value = 500000.00 WHERE address_line1='Langholme'          AND town='Tintagel';
UPDATE properties SET current_value = 600000.00 WHERE address_line1='The Olde Malthouse' AND town='Tintagel';

-- ── Re-weight the live mortgage (295905-02) across the three properties ────
-- Drop the old 50/50 link, then re-insert weighted across all three.
DELETE FROM property_mortgage_accounts
 WHERE mortgage_account_id = (SELECT id FROM mortgage_accounts
                               WHERE lender='Principality Commercial' AND account_ref='295905-02');

INSERT INTO property_mortgage_accounts (property_id, mortgage_account_id, share_pct, realm)
SELECT p.id, m.id,
       CASE p.address_line1
            WHEN '1 Castle Road'  THEN 54.79
            WHEN '2 Salutations'  THEN 20.09
            WHEN '3 Salutations'  THEN 25.12
       END,
       'work'
  FROM properties p
  JOIN mortgage_accounts m
    ON m.lender='Principality Commercial' AND m.account_ref='295905-02'
 WHERE p.address_line1 IN ('1 Castle Road','2 Salutations','3 Salutations')
   AND p.town = 'Tintagel';

-- ── v_mortgage_summary: include closed_date so UI can grey out ─────────────
DROP VIEW IF EXISTS v_mortgage_summary;
CREATE VIEW v_mortgage_summary AS
SELECT
    m.id,
    m.lender,
    m.account_ref,
    e.name AS borrower,
    m.product_type,
    m.current_balance,
    m.balance_as_of,
    m.monthly_payment,
    (m.interest_rate * 100)::numeric(5,3) AS interest_rate_pct,
    m.closed_date,
    (m.closed_date IS NULL) AS active,
    (
        SELECT string_agg(
                   p.address_line1 ||
                   CASE WHEN pma.share_pct < 100
                        THEN ' (' || pma.share_pct || '%)'
                        ELSE '' END,
                   ', ' ORDER BY p.address_line1)
          FROM property_mortgage_accounts pma
          JOIN properties p ON p.id = pma.property_id
         WHERE pma.mortgage_account_id = m.id
    ) AS secured_against,
    (
        SELECT count(*)::int FROM documents d
         WHERE d.linked_table = 'mortgage_accounts'
           AND d.linked_id = m.id
    ) AS document_count,
    m.notes
  FROM mortgage_accounts m
  JOIN entities e ON e.id = m.borrower_entity_id
 ORDER BY (m.closed_date IS NULL) DESC, m.current_balance DESC NULLS LAST;

GRANT SELECT ON v_mortgage_summary TO homeai_pipeline;

-- ── v_capital_summary: every property + value + mortgage on it ──────────────
CREATE OR REPLACE VIEW v_capital_summary AS
SELECT
    p.id,
    p.address_line1,
    p.town,
    p.postcode,
    p.property_type,
    e.name AS owner_entity,
    p.current_value,
    COALESCE((
        SELECT round(sum(m.current_balance * pma.share_pct / 100.0)::numeric, 2)
          FROM property_mortgage_accounts pma
          JOIN mortgage_accounts m ON m.id = pma.mortgage_account_id
         WHERE pma.property_id = p.id AND m.closed_date IS NULL
    ), 0) AS mortgage_share,
    (p.current_value - COALESCE((
        SELECT sum(m.current_balance * pma.share_pct / 100.0)
          FROM property_mortgage_accounts pma
          JOIN mortgage_accounts m ON m.id = pma.mortgage_account_id
         WHERE pma.property_id = p.id AND m.closed_date IS NULL
    ), 0))::numeric(12,2) AS equity
  FROM properties p
  JOIN entities e ON e.id = p.entity_id
 ORDER BY p.current_value DESC NULLS LAST;

GRANT SELECT ON v_capital_summary TO homeai_pipeline;

-- ── v_net_worth_summary: the single-row KPI ────────────────────────────────
CREATE OR REPLACE VIEW v_net_worth_summary AS
WITH props AS (
    SELECT COALESCE(sum(current_value), 0) AS property_value
      FROM properties
),
cash AS (
    SELECT COALESCE(sum(balance), 0) AS net_cash
      FROM v_account_balances_now WHERE is_liability = false
),
unsecured AS (
    SELECT COALESCE(sum(-balance), 0) AS unsecured_borrowing  -- credit cards stored negative
      FROM v_account_balances_now WHERE is_liability = true
),
secured AS (
    SELECT COALESCE(sum(current_balance), 0) AS secured_borrowing
      FROM mortgage_accounts WHERE closed_date IS NULL
)
SELECT
    props.property_value,
    cash.net_cash,
    secured.secured_borrowing,
    unsecured.unsecured_borrowing,
    (props.property_value + cash.net_cash) AS total_assets,
    (secured.secured_borrowing + unsecured.unsecured_borrowing) AS total_borrowing,
    (props.property_value + cash.net_cash
        - secured.secured_borrowing - unsecured.unsecured_borrowing)::numeric(14,2) AS net_worth
  FROM props, cash, unsecured, secured;

GRANT SELECT ON v_net_worth_summary TO homeai_pipeline;

-- ── slugs for the new finance tabs ─────────────────────────────────────────
INSERT INTO query_whitelist
    (slug, display_name, description, intent_examples, sql_template, param_schema,
     result_format, active, entity_id, created_by, approved_at, approved_by, realm)
SELECT * FROM (VALUES
    ('capital_summary', 'Capital position',
     'Properties + current valuation + mortgage exposure + equity per property.',
     ARRAY['what are my properties worth','show my equity','capital position']::text[],
     'SELECT address_line1, town, owner_entity, property_type, current_value, mortgage_share, equity FROM v_capital_summary',
     '{}'::jsonb, 'table', true, 3, 'u77', now(), 'u77', 'owner'),
    ('net_worth_summary', 'Net worth',
     'Single-row summary: property + cash − secured/unsecured borrowing = net worth.',
     ARRAY['my net worth','wealth position']::text[],
     'SELECT * FROM v_net_worth_summary',
     '{}'::jsonb, 'table', true, 3, 'u77', now(), 'u77', 'owner'),
    ('mortgages_all', 'Mortgages (incl. closed)',
     'Every mortgage account: active first, then closed (greyed in UI).',
     ARRAY['all mortgages','mortgage history']::text[],
     'SELECT lender, account_ref, borrower, current_balance, balance_as_of, monthly_payment, interest_rate_pct, secured_against, closed_date, active, document_count FROM v_mortgage_summary',
     '{}'::jsonb, 'table', true, 3, 'u77', now(), 'u77', 'owner')
) AS v(slug, display_name, description, intent_examples, sql_template, param_schema,
       result_format, active, entity_id, created_by, approved_at, approved_by, realm)
WHERE NOT EXISTS (SELECT 1 FROM query_whitelist q WHERE q.slug = v.slug);

COMMIT;
