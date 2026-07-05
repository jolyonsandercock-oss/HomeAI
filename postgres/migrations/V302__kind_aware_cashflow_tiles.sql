-- V302 (2026-07-05, U294 backlog #5) — kind-aware cashflow tiles.
--
-- v_finance_kpis' mtd_inflow_total / mtd_outflow_total summed
-- v_finance_monthly_summary.net across ALL bank_transactions categories,
-- including kind='transfer' (own-money moves between our own accounts —
-- card_repayment, inter_entity_transfer, internal_transfer,
-- transfer_uncategorised) and kind='neutral' (needs_review, personal_spend)
-- rows. Neither is real cash flowing in/out of the business; both inflated
-- both tiles.
--
-- Fix: join bank_category_registry and restrict the two tiles to categories
-- whose kind IN ('income','cost','tax','financing') — financing is real cash
-- leaving/arriving (loan draws/repayments, mortgage payments) so it stays in.
-- Every other column of v_finance_kpis is byte-identical to the prior
-- definition (V74/V294) — only the two tile subqueries changed.
--
-- Netting semantics preserved exactly as before: v_finance_monthly_summary
-- nets bank_transactions.amount PER (month, entity, realm, account_type,
-- category) group, and mtd_outflow_total/mtd_inflow_total sum only the
-- category-groups whose net is negative/positive respectively (i.e. this is
-- NOT a sum of individual negative/positive transactions — it's a sum of
-- already-netted category totals, same as the view being replaced).
--
-- Dedup caveat: v_finance_monthly_summary does not de-duplicate
-- bank_transactions rows (no row_number()/DISTINCT — it is a plain GROUP BY
-- over bt JOIN bank_accounts JOIN entities). This migration mirrors that:
-- it does not add dedup either, so it inherits whatever duplicate-row noise
-- exists upstream (see feedback_bank_txn_duplicate_rows memory). Fixing that
-- is a separate, larger change affecting every financial rollup in the
-- system, not just these two tiles — out of scope here.
--
-- Card-account sign caveat: bank_accounts for the four RBS Mastercards
-- (ids 11-14, 16-19 depending on entity) use inverted sign semantics
-- (a purchase is a positive amount, a payment negative) relative to normal
-- current accounts. Today those cards' transaction rows are almost all
-- categorised needs_review/neutral or transfer (card_repayment,
-- card_settlement), so they already drop out of the kind IN (...) filter
-- and the inverted signs never reach these two tiles. If card spend is ever
-- recategorised into 'cost' without a matching sign-normalisation step, the
-- inverted sign would then feed straight into mtd_outflow_total/
-- mtd_inflow_total — flagged here so a future categorisation change doesn't
-- reintroduce a sign bug silently.

CREATE OR REPLACE VIEW v_finance_kpis AS
 SELECT (( SELECT sum(v_account_balances_now.balance) AS sum
        FROM v_account_balances_now
       WHERE NOT v_account_balances_now.is_liability))::numeric(12,2) AS total_cash_balance,
    (( SELECT - sum(v_account_balances_now.balance)
        FROM v_account_balances_now
       WHERE v_account_balances_now.is_liability))::numeric(12,2) AS total_credit_card_debt,
    (( SELECT sum(vfms.net) AS sum
        FROM v_finance_monthly_summary vfms
        JOIN bank_category_registry bcr ON bcr.category = vfms.category
       WHERE vfms.month = date_trunc('month'::text, CURRENT_DATE::timestamp with time zone)::date
         AND bcr.kind IN ('income','cost','tax','financing')
         AND vfms.net < 0::numeric))::numeric(12,2) AS mtd_outflow_total,
    (( SELECT sum(vfms.net) AS sum
        FROM v_finance_monthly_summary vfms
        JOIN bank_category_registry bcr ON bcr.category = vfms.category
       WHERE vfms.month = date_trunc('month'::text, CURRENT_DATE::timestamp with time zone)::date
         AND bcr.kind IN ('income','cost','tax','financing')
         AND vfms.net > 0::numeric))::numeric(12,2) AS mtd_inflow_total,
    ( SELECT count(*) AS count
        FROM account_transfers
       WHERE account_transfers.transfer_date >= (CURRENT_DATE - '30 days'::interval)) AS transfers_30d,
    ( SELECT count(*) AS count
        FROM v_account_transfers_open) AS transfer_unpaired,
    (( SELECT sum(
             CASE
                 WHEN ba.account_type = 'credit_card'::text AND bt.amount > 0::numeric THEN bt.amount
                 WHEN ba.account_type <> 'credit_card'::text AND bt.amount < 0::numeric THEN - bt.amount
                 ELSE 0::numeric
             END) AS sum
        FROM bank_transactions bt
          JOIN bank_accounts ba ON ba.id = bt.bank_account_id
       WHERE bt.category = 'interest_charged'::text AND bt.transaction_date >= (CURRENT_DATE - '1 year'::interval)))::numeric(12,2) AS interest_paid_12m,
    (( SELECT sum(
             CASE
                 WHEN ba.account_type = 'credit_card'::text AND bt.amount > 0::numeric THEN bt.amount
                 WHEN ba.account_type <> 'credit_card'::text AND bt.amount < 0::numeric THEN - bt.amount
                 ELSE 0::numeric
             END) AS sum
        FROM bank_transactions bt
          JOIN bank_accounts ba ON ba.id = bt.bank_account_id
       WHERE bt.category = 'bank_fee'::text AND bt.transaction_date >= (CURRENT_DATE - '1 year'::interval)))::numeric(12,2) AS fees_paid_12m,
    (( SELECT sum(v_account_balances_now.balance) AS sum
        FROM v_account_balances_now))::numeric(12,2) AS net_worth;
