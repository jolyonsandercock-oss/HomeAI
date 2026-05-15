-- =============================================================================
-- V75 — Show credit-card balances as negative numbers
-- =============================================================================
-- Convention change: in v_account_balances_now, a credit_card account's
-- balance is now stored as a NEGATIVE figure (money you owe = a negative
-- net-worth contribution). is_liability still flags the row so UIs can
-- colour it accordingly.
--
-- v_finance_kpis.total_credit_card_debt stays a POSITIVE magnitude ("how
-- much owed") — that's the friendliest number for the KPI tile. We just
-- negate the sum to get it.
-- =============================================================================

BEGIN;

CREATE OR REPLACE VIEW v_account_balances_now AS
WITH latest_balance AS (
    SELECT DISTINCT ON (bank_account_id)
        bank_account_id, transaction_date, balance
      FROM bank_transactions
     WHERE balance IS NOT NULL
     ORDER BY bank_account_id, transaction_date DESC, id DESC
),
running_sum AS (
    SELECT bank_account_id, SUM(amount)::numeric(12,2) AS rsum,
           MAX(transaction_date) AS dlast
      FROM bank_transactions
     GROUP BY bank_account_id
)
SELECT
    ba.id,
    ba.entity_id,
    e.name AS entity_name,
    ba.realm,
    ba.bank_name,
    ba.account_name,
    ba.account_number,
    ba.account_type,
    -- Credit-card raw balance is stored positive (= how much you owe). Flip
    -- it so a card balance contributes negatively to your net worth, in
    -- line with how every other balance signs: positive=asset, negative=debt.
    (CASE WHEN ba.account_type = 'credit_card'
          THEN -COALESCE(lb.balance, rs.rsum)
          ELSE  COALESCE(lb.balance, rs.rsum) END)::numeric(12,2) AS balance,
    COALESCE(lb.transaction_date, rs.dlast) AS as_of_date,
    CASE WHEN lb.balance IS NOT NULL THEN 'bank_balance_field'
         ELSE 'running_sum_fallback' END AS source,
    CASE WHEN ba.account_type = 'credit_card' THEN true ELSE false END AS is_liability
  FROM bank_accounts ba
  JOIN entities e ON e.id = ba.entity_id
  LEFT JOIN latest_balance lb ON lb.bank_account_id = ba.id
  LEFT JOIN running_sum    rs ON rs.bank_account_id = ba.id
 ORDER BY ba.entity_id, ba.account_type, ba.account_name;

COMMENT ON VIEW v_account_balances_now IS
    'Latest balance per bank_account. Sign convention: positive = asset, '
    'negative = debt (credit cards always negative, overdrawn currents too).';

-- KPI tile keeps the friendly "how much owed" framing (positive number).
-- New column `net_worth` is appended at the end so CREATE OR REPLACE is legal
-- (Postgres won't let you reorder/rename columns on an existing view).
CREATE OR REPLACE VIEW v_finance_kpis AS
SELECT
    (SELECT SUM(balance) FROM v_account_balances_now WHERE NOT is_liability)::numeric(12,2)
        AS total_cash_balance,
    (SELECT -SUM(balance) FROM v_account_balances_now WHERE is_liability)::numeric(12,2)
        AS total_credit_card_debt,
    (SELECT SUM(net) FROM v_finance_monthly_summary
      WHERE month = DATE_TRUNC('month', CURRENT_DATE)::date AND net < 0)::numeric(12,2)
        AS mtd_outflow_total,
    (SELECT SUM(net) FROM v_finance_monthly_summary
      WHERE month = DATE_TRUNC('month', CURRENT_DATE)::date AND net > 0)::numeric(12,2)
        AS mtd_inflow_total,
    (SELECT COUNT(*) FROM account_transfers
      WHERE transfer_date >= CURRENT_DATE - INTERVAL '30 days')
        AS transfers_30d,
    (SELECT COUNT(*) FROM v_account_transfers_open) AS transfer_unpaired,
    (SELECT SUM(
        CASE WHEN ba.account_type = 'credit_card' AND bt.amount > 0 THEN bt.amount
             WHEN ba.account_type <> 'credit_card' AND bt.amount < 0 THEN -bt.amount
             ELSE 0 END)
       FROM bank_transactions bt JOIN bank_accounts ba ON ba.id = bt.bank_account_id
      WHERE bt.category = 'interest_charged'
        AND bt.transaction_date >= CURRENT_DATE - INTERVAL '12 months')::numeric(12,2)
        AS interest_paid_12m,
    (SELECT SUM(
        CASE WHEN ba.account_type = 'credit_card' AND bt.amount > 0 THEN bt.amount
             WHEN ba.account_type <> 'credit_card' AND bt.amount < 0 THEN -bt.amount
             ELSE 0 END)
       FROM bank_transactions bt JOIN bank_accounts ba ON ba.id = bt.bank_account_id
      WHERE bt.category = 'bank_fee'
        AND bt.transaction_date >= CURRENT_DATE - INTERVAL '12 months')::numeric(12,2)
        AS fees_paid_12m,
    -- Net worth across every account, signed (CC now contributes negatively).
    (SELECT SUM(balance) FROM v_account_balances_now)::numeric(12,2)
        AS net_worth;

COMMENT ON VIEW v_finance_kpis IS
    'Single-row finance KPI pack. total_credit_card_debt stays positive '
    '(magnitude); net_worth signs everything together.';

COMMIT;
