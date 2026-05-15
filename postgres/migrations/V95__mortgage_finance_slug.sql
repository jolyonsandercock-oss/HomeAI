-- =============================================================================
-- V95 — Mortgages slug for /finance tab (U74)
-- =============================================================================
-- Adds:
--   - v_mortgage_summary view (one row per loan, with comma-joined properties)
--   - query_whitelist row 'mortgages_summary' for the new /finance tab
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

CREATE OR REPLACE VIEW v_mortgage_summary AS
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
 WHERE m.closed_date IS NULL
 ORDER BY m.current_balance DESC NULLS LAST;

GRANT SELECT ON v_mortgage_summary TO homeai_pipeline;

INSERT INTO query_whitelist
    (slug, display_name, description, intent_examples, sql_template,
     param_schema, result_format, active, entity_id, created_by, approved_at, approved_by, realm)
SELECT
    'mortgages_summary',
    'Mortgages',
    'Active mortgages with lender, balance, properties secured, and document count.',
    ARRAY['show my mortgages','what mortgages do i have','outstanding loans']::text[],
    'SELECT lender, account_ref, borrower, product_type, current_balance, '
    'balance_as_of, monthly_payment, interest_rate_pct, secured_against, document_count '
    'FROM v_mortgage_summary',
    '{}'::jsonb,
    'table',
    true,
    3,
    'u74',
    now(),
    'u74',
    'owner'
WHERE NOT EXISTS (SELECT 1 FROM query_whitelist WHERE slug='mortgages_summary');

COMMIT;
