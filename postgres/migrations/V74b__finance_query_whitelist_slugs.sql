-- =============================================================================
-- V74b — Seed finance slugs into query_whitelist for /finance NL box
-- =============================================================================
-- Each slug is approved at insert-time (approved_by='system_v74b') so the
-- bot-responder + /api/finance/ask will list them as tools immediately.
-- Entity_id=3 is the canonical "owner-realm" anchor; realm='owner' so the
-- whole set is visible to Jo. Re-runnable — ON CONFLICT (slug) DO UPDATE.
-- =============================================================================

BEGIN;

INSERT INTO query_whitelist
    (slug, display_name, description, intent_examples, sql_template,
     param_schema, result_format, active, entity_id, created_by,
     approved_at, approved_by, realm)
VALUES

-- ──────────────────────────────────────────────────────────────────────────
-- 1. interest_paid_window
-- ──────────────────────────────────────────────────────────────────────────
('interest_paid_window',
 'Interest paid in the last N days',
 'Sum of interest charged across every account in the window. Combines '
 'credit-card interest (positive amount on the card) with overdraft '
 'interest (negative amount on a current account) into a single "cost '
 'to you" figure broken out per account.',
 ARRAY[
   'how much interest have I paid',
   'how much interest in the last year',
   'interest on my credit cards',
   'overdraft interest cost'
 ],
$$
WITH window_data AS (
  SELECT
    ba.account_name,
    ba.account_type,
    CASE WHEN ba.account_type = 'credit_card' AND bt.amount > 0 THEN bt.amount
         WHEN ba.account_type <> 'credit_card' AND bt.amount < 0 THEN -bt.amount
         ELSE 0 END AS cost
   FROM bank_transactions bt
   JOIN bank_accounts ba ON ba.id = bt.bank_account_id
  WHERE bt.category = 'interest_charged'
    AND bt.transaction_date >= CURRENT_DATE - :days * INTERVAL '1 day'
)
SELECT account_name, account_type, COUNT(*) AS n_charges,
       SUM(cost)::numeric(12,2) AS interest_paid
  FROM window_data
 GROUP BY account_name, account_type
 ORDER BY interest_paid DESC
$$,
 '{"days": {"type":"int","min":1,"max":3650,"required":false,"default":365}}'::jsonb,
 'table', true, 3, 'system_v74b', now(), 'system_v74b', 'owner'),

-- ──────────────────────────────────────────────────────────────────────────
-- 2. fees_paid_window
-- ──────────────────────────────────────────────────────────────────────────
('fees_paid_window',
 'Bank fees + card fees in the last N days',
 'Sum of "bank_fee" category — service charges, FX fees, returned-item '
 'fees, unauthorised-overdraft fees — across every account.',
 ARRAY[
   'how much in fees',
   'show me bank fees',
   'card fees last year',
   'fx fees'
 ],
$$
WITH window_data AS (
  SELECT
    ba.account_name,
    ba.account_type,
    CASE WHEN ba.account_type = 'credit_card' AND bt.amount > 0 THEN bt.amount
         WHEN ba.account_type <> 'credit_card' AND bt.amount < 0 THEN -bt.amount
         ELSE 0 END AS cost
   FROM bank_transactions bt
   JOIN bank_accounts ba ON ba.id = bt.bank_account_id
  WHERE bt.category = 'bank_fee'
    AND bt.transaction_date >= CURRENT_DATE - :days * INTERVAL '1 day'
)
SELECT account_name, account_type, COUNT(*) AS n_charges,
       SUM(cost)::numeric(12,2) AS fees_paid
  FROM window_data
 GROUP BY account_name, account_type
 ORDER BY fees_paid DESC
$$,
 '{"days": {"type":"int","min":1,"max":3650,"required":false,"default":365}}'::jsonb,
 'table', true, 3, 'system_v74b', now(), 'system_v74b', 'owner'),

-- ──────────────────────────────────────────────────────────────────────────
-- 3. account_balances
-- ──────────────────────────────────────────────────────────────────────────
('account_balances',
 'Latest balance on every account',
 'Most recent balance on each bank or credit-card account. is_liability=true '
 'means the figure is what you owe (credit-card debt).',
 ARRAY[
   'what are my balances',
   'how much in my accounts',
   'show me account balances',
   'how much do I owe on cards'
 ],
$$
SELECT entity_name, account_name, account_type, balance, is_liability, as_of_date
  FROM v_account_balances_now
 ORDER BY is_liability, entity_id, account_type, account_name
$$,
 '{}'::jsonb,
 'table', true, 3, 'system_v74b', now(), 'system_v74b', 'owner'),

-- ──────────────────────────────────────────────────────────────────────────
-- 4. owings_summary
-- ──────────────────────────────────────────────────────────────────────────
('owings_summary',
 'Net flow between each pair of entities',
 'For every pair of entities that have moved money to each other, the '
 'gross flow each way and the net. Useful to see at a glance who is '
 'effectively funding whom.',
 ARRAY[
   'which entity owes whom what',
   'inter-entity transfers',
   'how much has AREL paid me',
   'who owes whom'
 ],
$$
SELECT entity_a_name, entity_b_name, n_transfers,
       gross_a_to_b, gross_b_to_a, net_flow_a_to_b,
       first_transfer, last_transfer
  FROM v_inter_entity_owings
$$,
 '{}'::jsonb,
 'table', true, 3, 'system_v74b', now(), 'system_v74b', 'owner'),

-- ──────────────────────────────────────────────────────────────────────────
-- 5. monthly_finance_costs
-- ──────────────────────────────────────────────────────────────────────────
('monthly_finance_costs',
 'Interest + fees per month for the last N months',
 'Time-series: out-of-pocket cost of borrowing per month, broken out into '
 'interest and fees.',
 ARRAY[
   'monthly interest cost',
   'how is interest trending',
   'fees and interest by month'
 ],
$$
SELECT
  DATE_TRUNC('month', bt.transaction_date)::date AS month,
  SUM(CASE WHEN bt.category='interest_charged'
           THEN CASE WHEN ba.account_type='credit_card' AND bt.amount>0 THEN bt.amount
                     WHEN ba.account_type<>'credit_card' AND bt.amount<0 THEN -bt.amount
                     ELSE 0 END
           ELSE 0 END)::numeric(12,2) AS interest_paid,
  SUM(CASE WHEN bt.category='bank_fee'
           THEN CASE WHEN ba.account_type='credit_card' AND bt.amount>0 THEN bt.amount
                     WHEN ba.account_type<>'credit_card' AND bt.amount<0 THEN -bt.amount
                     ELSE 0 END
           ELSE 0 END)::numeric(12,2) AS fees_paid
  FROM bank_transactions bt
  JOIN bank_accounts ba ON ba.id = bt.bank_account_id
 WHERE bt.transaction_date >= DATE_TRUNC('month', CURRENT_DATE) - :months * INTERVAL '1 month'
   AND bt.category IN ('interest_charged','bank_fee')
 GROUP BY 1
 ORDER BY 1 DESC
$$,
 '{"months": {"type":"int","min":1,"max":60,"required":false,"default":12}}'::jsonb,
 'table', true, 3, 'system_v74b', now(), 'system_v74b', 'owner'),

-- ──────────────────────────────────────────────────────────────────────────
-- 6. top_vendors_window
-- ──────────────────────────────────────────────────────────────────────────
('top_vendors_window',
 'Top vendors by total billed in the last N months',
 'Roll-up of vendor_invoice_inbox by vendor with totals + count + last seen.',
 ARRAY[
   'who do I spend most with',
   'biggest suppliers',
   'top vendors',
   'most invoiced'
 ],
$$
SELECT vendor, entity_id, n_invoices, total_seen, last_invoice_date
  FROM v_top_vendors_window
 LIMIT :limit
$$,
 '{"limit": {"type":"int","min":1,"max":200,"required":false,"default":25}}'::jsonb,
 'table', true, 3, 'system_v74b', now(), 'system_v74b', 'owner'),

-- ──────────────────────────────────────────────────────────────────────────
-- 7. transfers_recent
-- ──────────────────────────────────────────────────────────────────────────
('transfers_recent',
 'Recent paired account-to-account transfers',
 'Most recent rows from account_transfers, showing source account, dest '
 'account, amount and confidence. Use it to see CC-payment pairings and '
 'inter-entity moves.',
 ARRAY[
   'show me recent transfers',
   'recent inter-account moves',
   'recent credit card payments'
 ],
$$
SELECT at.transfer_date,
       src_ba.account_name AS from_acct,
       dst_ba.account_name AS to_acct,
       at.amount,
       at.confidence,
       at.detection_method
  FROM account_transfers at
  JOIN bank_transactions src_bt ON src_bt.id = at.src_txn_id
  JOIN bank_transactions dst_bt ON dst_bt.id = at.dst_txn_id
  JOIN bank_accounts src_ba ON src_ba.id = src_bt.bank_account_id
  JOIN bank_accounts dst_ba ON dst_ba.id = dst_bt.bank_account_id
 ORDER BY at.transfer_date DESC, at.id DESC
 LIMIT :limit
$$,
 '{"limit": {"type":"int","min":1,"max":200,"required":false,"default":50}}'::jsonb,
 'table', true, 3, 'system_v74b', now(), 'system_v74b', 'owner'),

-- ──────────────────────────────────────────────────────────────────────────
-- 8. spend_by_category_window
-- ──────────────────────────────────────────────────────────────────────────
('spend_by_category_window',
 'Outflow grouped by category in the last N days',
 'Every outgoing pound categorised — vendor_payment, payroll, tax_payment, '
 'direct_debit, loan_repayment, etc. — across every account.',
 ARRAY[
   'where is my money going',
   'spend by category',
   'biggest outflows',
   'how much on tax this year'
 ],
$$
SELECT bt.category,
       COUNT(*) AS n,
       SUM(CASE WHEN ba.account_type='credit_card' AND bt.amount>0 THEN bt.amount
                WHEN ba.account_type<>'credit_card' AND bt.amount<0 THEN -bt.amount
                ELSE 0 END)::numeric(12,2) AS outflow
  FROM bank_transactions bt
  JOIN bank_accounts ba ON ba.id = bt.bank_account_id
 WHERE bt.transaction_date >= CURRENT_DATE - :days * INTERVAL '1 day'
   AND bt.category IS NOT NULL
 GROUP BY bt.category
 ORDER BY outflow DESC
$$,
 '{"days": {"type":"int","min":1,"max":3650,"required":false,"default":365}}'::jsonb,
 'table', true, 3, 'system_v74b', now(), 'system_v74b', 'owner'),

-- ──────────────────────────────────────────────────────────────────────────
-- 9. credit_card_status
-- ──────────────────────────────────────────────────────────────────────────
('credit_card_status',
 'Latest statement per credit card',
 'Latest closing balance, min payment, credit limit, due date per card.',
 ARRAY[
   'credit card status',
   'how much do I owe on cards',
   'card balances',
   'when is my minimum payment due'
 ],
$$
SELECT account_name, statement_date, opening_balance, payments_credited,
       spending_charged, closing_balance, min_payment, min_payment_due_date,
       credit_limit
  FROM v_card_statements_summary
 WHERE statement_date = (SELECT MAX(statement_date) FROM card_statements cs2
                          WHERE cs2.bank_account_id = v_card_statements_summary.bank_account_id)
 ORDER BY account_name
$$,
 '{}'::jsonb,
 'table', true, 3, 'system_v74b', now(), 'system_v74b', 'owner'),

-- ──────────────────────────────────────────────────────────────────────────
-- 10. recent_finance_events
-- ──────────────────────────────────────────────────────────────────────────
('recent_finance_events',
 'Recent finance events across all sources',
 'Last N rows from v_finance_recent_unified — bank txns, invoices and '
 'dojo settlements combined in one feed.',
 ARRAY[
   'show me recent activity',
   'latest finance events',
   'recent transactions'
 ],
$$
SELECT event_date, source, account_name, description, amount, category
  FROM v_finance_recent_unified
 ORDER BY event_date DESC
 LIMIT :limit
$$,
 '{"limit": {"type":"int","min":1,"max":500,"required":false,"default":50}}'::jsonb,
 'table', true, 3, 'system_v74b', now(), 'system_v74b', 'owner'),

-- ──────────────────────────────────────────────────────────────────────────
-- 11. finance_kpis
-- ──────────────────────────────────────────────────────────────────────────
('finance_kpis',
 'Single-row KPI pack',
 'Cash balance total, credit-card debt total, month-to-date in/out, '
 'transfers in last 30d, interest + fees for the last 12 months.',
 ARRAY[
   'finance summary',
   'overall position',
   'overview',
   'where am I right now financially'
 ],
$$
SELECT * FROM v_finance_kpis
$$,
 '{}'::jsonb,
 'table', true, 3, 'system_v74b', now(), 'system_v74b', 'owner')

ON CONFLICT (slug) DO UPDATE SET
    display_name     = EXCLUDED.display_name,
    description      = EXCLUDED.description,
    intent_examples  = EXCLUDED.intent_examples,
    sql_template     = EXCLUDED.sql_template,
    param_schema     = EXCLUDED.param_schema,
    result_format    = EXCLUDED.result_format,
    active           = EXCLUDED.active,
    approved_at      = COALESCE(query_whitelist.approved_at, EXCLUDED.approved_at),
    approved_by      = COALESCE(query_whitelist.approved_by, EXCLUDED.approved_by);

-- Verification
DO $$
DECLARE
    n INT;
BEGIN
    SELECT COUNT(*) INTO n FROM query_whitelist
     WHERE slug IN ('interest_paid_window','fees_paid_window','account_balances',
                    'owings_summary','monthly_finance_costs','top_vendors_window',
                    'transfers_recent','spend_by_category_window','credit_card_status',
                    'recent_finance_events','finance_kpis');
    IF n < 11 THEN
        RAISE EXCEPTION 'V74b verification failed: only % of 11 slugs landed', n;
    END IF;
    RAISE NOTICE 'V74b verification PASS: % finance slugs active.', n;
END $$;

COMMIT;
