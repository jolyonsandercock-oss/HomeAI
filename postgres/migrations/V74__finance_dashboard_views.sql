-- =============================================================================
-- V74 — Finance dashboard views
-- =============================================================================
-- Built for the new /finance page. Pulls together bank, credit-card, transfers,
-- invoices, dojo into a coherent set of queries.
--
-- Views:
--   v_inter_entity_owings       — net flow per entity-pair from account_transfers
--   v_account_balances_now      — most recent known balance per bank_account
--   v_finance_monthly_summary   — per (month, entity, kind): inflow, outflow, fees, interest
--   v_finance_recent_unified    — last 90d of all finance events in one feed
--   v_top_vendors_window        — vendor_invoice_inbox + bank_transactions(vendor_payment)
--                                 rolled up to one row per vendor
--   v_finance_kpis              — single-row scalar pack: balances, debt, MoM movement
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. v_inter_entity_owings
--    Each entity-pair appears once (lower entity_id first as "a"). Positive
--    net_flow_a_to_b means A has paid B more than B has paid A — i.e. money
--    has moved net A → B. Whether that constitutes a debt depends on the
--    legal relationship between A and B; the view stays neutral and lets the
--    UI label it.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_inter_entity_owings AS
WITH directed AS (
    SELECT
        LEAST(src_bt.entity_id, dst_bt.entity_id)    AS a_id,
        GREATEST(src_bt.entity_id, dst_bt.entity_id) AS b_id,
        at.amount,
        CASE WHEN src_bt.entity_id <= dst_bt.entity_id THEN at.amount ELSE -at.amount END AS signed_amt,
        at.transfer_date,
        at.realm
      FROM account_transfers at
      JOIN bank_transactions src_bt ON src_bt.id = at.src_txn_id
      JOIN bank_transactions dst_bt ON dst_bt.id = at.dst_txn_id
     WHERE src_bt.entity_id <> dst_bt.entity_id
)
SELECT
    a_id AS entity_a_id,
    ea.name AS entity_a_name,
    b_id AS entity_b_id,
    eb.name AS entity_b_name,
    COUNT(*) AS n_transfers,
    SUM(CASE WHEN signed_amt > 0 THEN signed_amt ELSE 0 END)::numeric(12,2)  AS gross_a_to_b,
    SUM(CASE WHEN signed_amt < 0 THEN -signed_amt ELSE 0 END)::numeric(12,2) AS gross_b_to_a,
    SUM(signed_amt)::numeric(12,2) AS net_flow_a_to_b,
    MIN(transfer_date) AS first_transfer,
    MAX(transfer_date) AS last_transfer
  FROM directed d
  JOIN entities ea ON ea.id = d.a_id
  JOIN entities eb ON eb.id = d.b_id
 GROUP BY a_id, ea.name, b_id, eb.name
 ORDER BY ABS(SUM(signed_amt)) DESC;

COMMENT ON VIEW v_inter_entity_owings IS
    'Net flow per entity-pair from confirmed account_transfers. Positive '
    'net_flow_a_to_b = A has paid net £N to B. Excludes 737 unpaired '
    'transfer rows still in v_account_transfers_open.';

-- -----------------------------------------------------------------------------
-- 2. v_account_balances_now — latest balance per bank_account
--    For accounts with a populated balance column (NatWest debit + CC),
--    pick the most recent transaction's balance. For accounts where balance
--    is always NULL we fall back to running SUM(amount).
-- -----------------------------------------------------------------------------

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
    COALESCE(lb.balance, rs.rsum)::numeric(12,2) AS balance,
    COALESCE(lb.transaction_date, rs.dlast)     AS as_of_date,
    CASE WHEN lb.balance IS NOT NULL THEN 'bank_balance_field'
         ELSE 'running_sum_fallback' END AS source,
    -- credit card: a positive balance = you owe the bank; a negative = the
    -- bank owes you (overpayment). Flag this for the UI so it can label "owed".
    CASE WHEN ba.account_type = 'credit_card' THEN true ELSE false END AS is_liability
  FROM bank_accounts ba
  JOIN entities e ON e.id = ba.entity_id
  LEFT JOIN latest_balance lb ON lb.bank_account_id = ba.id
  LEFT JOIN running_sum    rs ON rs.bank_account_id = ba.id
 ORDER BY ba.entity_id, ba.account_type, ba.account_name;

COMMENT ON VIEW v_account_balances_now IS
    'Latest known balance per bank_account. is_liability=true for credit cards.';

-- -----------------------------------------------------------------------------
-- 3. v_finance_monthly_summary
--    Per (month, entity, account_type, category bucket): inflow / outflow / count.
--    Cards and current accounts share the bucket so net spend rolls up
--    coherently per entity.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_finance_monthly_summary AS
SELECT
    DATE_TRUNC('month', bt.transaction_date)::date AS month,
    ba.entity_id,
    e.name AS entity_name,
    ba.realm,
    ba.account_type,
    bt.category,
    COUNT(*) AS n,
    SUM(CASE WHEN bt.amount > 0 THEN bt.amount ELSE 0 END)::numeric(12,2) AS inflow,
    SUM(CASE WHEN bt.amount < 0 THEN -bt.amount ELSE 0 END)::numeric(12,2) AS outflow,
    SUM(bt.amount)::numeric(12,2) AS net
  FROM bank_transactions bt
  JOIN bank_accounts ba ON ba.id = bt.bank_account_id
  JOIN entities e ON e.id = ba.entity_id
 GROUP BY 1,2,3,4,5,6
 ORDER BY 1 DESC, 2, 4, 5;

COMMENT ON VIEW v_finance_monthly_summary IS
    'Per-month rollup: one row per (month, entity, account_type, category).';

-- -----------------------------------------------------------------------------
-- 4. v_finance_recent_unified
--    Last 90d feed of every finance event in one stream — for the
--    "Recent activity" tab on /finance.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_finance_recent_unified AS
SELECT
    bt.transaction_date                AS event_date,
    'bank_txn'                         AS source,
    bt.id                              AS source_id,
    bt.entity_id,
    ba.realm,
    ba.account_name,
    bt.description,
    bt.amount,
    bt.category,
    bt.category_confidence,
    NULL::text                         AS counterparty
  FROM bank_transactions bt
  JOIN bank_accounts ba ON ba.id = bt.bank_account_id
 WHERE bt.transaction_date >= CURRENT_DATE - INTERVAL '90 days'

UNION ALL

SELECT
    vii.invoice_date                   AS event_date,
    'invoice'                          AS source,
    vii.id                             AS source_id,
    vii.entity_id,
    'work'::text                       AS realm,
    COALESCE(vii.vendor_name, vii.vendor_domain) AS account_name,
    vii.subject                        AS description,
    -COALESCE(vii.amount_seen, 0)::numeric(12,2) AS amount,
    'vendor_invoice'                   AS category,
    NULL::numeric(4,3)                 AS category_confidence,
    vii.vendor_domain                  AS counterparty
  FROM vendor_invoice_inbox vii
 WHERE COALESCE(vii.invoice_date, vii.received_at::date) >= CURRENT_DATE - INTERVAL '90 days'

UNION ALL

SELECT
    dt.transaction_date                AS event_date,
    'dojo_settlement'                  AS source,
    dt.id                              AS source_id,
    dt.entity_id,
    'work'::text                       AS realm,
    dt.site                            AS account_name,
    'Dojo card take ' || dt.site       AS description,
    dt.transaction_amount              AS amount,
    'card_settlement'                  AS category,
    NULL::numeric(4,3),
    'dojo'                             AS counterparty
  FROM dojo_transactions dt
 WHERE dt.transaction_date >= CURRENT_DATE - INTERVAL '90 days'

 ORDER BY event_date DESC, source_id DESC;

COMMENT ON VIEW v_finance_recent_unified IS
    'Last 90d of every finance event — bank txn, invoice, dojo settlement — '
    'in one stream for /finance recent-activity tab.';

-- -----------------------------------------------------------------------------
-- 5. v_top_vendors_window — vendor-side rollup (12-month default window).
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_top_vendors_window AS
SELECT
    COALESCE(vii.vendor_name, vii.vendor_domain) AS vendor,
    vii.entity_id,
    COUNT(*) AS n_invoices,
    SUM(COALESCE(vii.amount_seen, 0))::numeric(12,2) AS total_seen,
    MAX(vii.invoice_date) AS last_invoice_date
  FROM vendor_invoice_inbox vii
 WHERE vii.invoice_date >= CURRENT_DATE - INTERVAL '12 months'
 GROUP BY 1, 2
 ORDER BY total_seen DESC NULLS LAST;

COMMENT ON VIEW v_top_vendors_window IS
    'Top vendors by 12-month spend, from vendor_invoice_inbox.';

-- -----------------------------------------------------------------------------
-- 6. v_finance_kpis — scalar pack
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_finance_kpis AS
SELECT
    (SELECT SUM(balance) FROM v_account_balances_now WHERE NOT is_liability)::numeric(12,2)
        AS total_cash_balance,
    (SELECT SUM(balance) FROM v_account_balances_now WHERE is_liability AND balance > 0)::numeric(12,2)
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
    -- "Cost to Jo": a positive amount on a credit-card row is a charge (cost);
    -- on a debit account a negative amount is a cost. Convert both into a
    -- consistent positive "out-of-pocket" figure.
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
        AS fees_paid_12m;

COMMENT ON VIEW v_finance_kpis IS
    'Single-row finance KPI pack for the /finance hero strip.';

COMMIT;
