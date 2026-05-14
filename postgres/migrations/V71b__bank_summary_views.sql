-- =============================================================================
-- V71b — Bank summary views (Phase A wrap)
-- =============================================================================
-- Three views to immediately surface what's in the imported NatWest data:
--
--   v_bank_category_month_summary — by month × entity × category
--   v_bank_recurring_charges      — recurring DDs/SOs (≥3 months with avg)
--   v_bank_interest_cost_summary  — interest paid vs received per entity per quarter
-- =============================================================================

BEGIN;

CREATE OR REPLACE VIEW v_bank_category_month_summary AS
SELECT
    DATE_TRUNC('month', bt.transaction_date)::date AS month,
    bt.entity_id,
    e.name                                          AS entity_name,
    bt.realm,
    bt.category,
    COUNT(*)                                        AS n,
    SUM(GREATEST(bt.amount, 0))::numeric(12,2)      AS sum_in,
    SUM(LEAST(bt.amount, 0))::numeric(12,2)         AS sum_out,
    SUM(bt.amount)::numeric(12,2)                   AS net
  FROM bank_transactions bt
  LEFT JOIN entities e ON e.id = bt.entity_id
 GROUP BY 1, 2, 3, 4, 5
 ORDER BY 1 DESC, 2, 5;

COMMENT ON VIEW v_bank_category_month_summary IS
    'Phase A analytic spine: rolled-up bank activity by (month, entity, category).';


CREATE OR REPLACE VIEW v_bank_recurring_charges AS
WITH per_month AS (
    SELECT
        bt.entity_id,
        bt.bank_account_id,
        SPLIT_PART(bt.description, ',', 1)             AS payee,
        DATE_TRUNC('month', bt.transaction_date)::date AS month,
        bt.amount
      FROM bank_transactions bt
     WHERE bt.category IN ('direct_debit','loan_repayment')
       AND bt.amount < 0
),
agg AS (
    SELECT
        entity_id,
        bank_account_id,
        TRIM(payee)                       AS payee,
        COUNT(DISTINCT month)             AS months_active,
        MIN(month)                        AS first_seen,
        MAX(month)                        AS last_seen,
        ROUND(AVG(amount)::numeric, 2)    AS avg_amount,
        ROUND(STDDEV(amount)::numeric, 2) AS stddev_amount,
        COUNT(*)                          AS hits
      FROM per_month
     GROUP BY 1, 2, 3
)
SELECT a.*,
       ba.account_name,
       ABS(a.avg_amount * 12) AS annual_run_rate
  FROM agg a
  JOIN bank_accounts ba ON ba.id = a.bank_account_id
 WHERE a.months_active >= 3
 ORDER BY ABS(a.avg_amount * 12) DESC;

COMMENT ON VIEW v_bank_recurring_charges IS
    'Phase A analytic: recurring DDs / loan repayments — at least 3 months '
    'in a row. Sorted by annual run-rate. Use to spot creeping subscriptions.';


CREATE OR REPLACE VIEW v_bank_interest_cost_summary AS
SELECT
    DATE_TRUNC('quarter', bt.transaction_date)::date AS quarter,
    bt.entity_id,
    e.name AS entity_name,
    SUM(CASE WHEN bt.category='interest_charged' THEN -bt.amount ELSE 0 END)::numeric(12,2) AS interest_paid,
    SUM(CASE WHEN bt.category='interest_credit'  THEN  bt.amount ELSE 0 END)::numeric(12,2) AS interest_received,
    SUM(CASE WHEN bt.category='interest_charged' THEN -bt.amount ELSE 0 END
      - CASE WHEN bt.category='interest_credit'  THEN  bt.amount ELSE 0 END)::numeric(12,2) AS net_interest_cost
  FROM bank_transactions bt
  LEFT JOIN entities e ON e.id = bt.entity_id
 WHERE bt.category IN ('interest_charged','interest_credit')
 GROUP BY 1, 2, 3
 ORDER BY 1 DESC, 2;

COMMENT ON VIEW v_bank_interest_cost_summary IS
    'Phase A analytic: net interest cost (charged minus received) per entity '
    'per quarter. Useful for the overdraft-cost discussion and to spot any '
    'entity where the interest line is creeping.';

COMMIT;
