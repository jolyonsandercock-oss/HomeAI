-- V297 — U294 Task 6 consumer-audit fixes.
--
-- Two of the 13 audited finance views carried a concrete misstatement caused
-- by the V294 taxonomy change (registry + kind column, needs_review replacing
-- true NULL, new own-account transfer categories from Task 2's pairing
-- signals). Both are fixed here as CREATE OR REPLACE VIEW (same output
-- columns/types, only the WHERE predicate changes). All other 11 audited
-- views were either unaffected or (v_bank_recurring_charges) flagged as a
-- forward-risk cosmetic issue with zero live impact today — deliberately not
-- touched, per scope-fence.
--
-- 1) v_uncategorised_summary — was `WHERE bt.category IS NULL`. Since Task 5
--    swept every remaining NULL to category='needs_review' (true NULL = 0
--    rows, verified in scripts/u294-acceptance.sql), this predicate now
--    always matches 0 rows, silently hiding the 11,109 deduped rows /
--    £4.4M still needing human review. The view's purpose (surfacing
--    uncategorised transactions for review) is unchanged by the taxonomy
--    migration — only the sentinel value moved from NULL to 'needs_review'.
--
-- 2) v_account_transfers_open — was
--    `WHERE category IN ('inter_entity_transfer','transfer_uncategorised')`.
--    Task 2's own-account transfer pairing (u294-transfer-pairing.sql) now
--    writes 'internal_transfer' / 'card_repayment' directly instead of the
--    legacy 'transfer_uncategorised' placeholder. Rows tagged with the new
--    categories that are still unmatched in account_transfers (the view's
--    whole job: surface *unpaired* transfer-kind rows) were invisible to
--    this view — 220 rows all-time (65 card_repayment + 155 internal_transfer)
--    as of 2026-07-05, none of them phantom, all genuinely unmatched. Made
--    kind-driven against bank_category_registry so any future transfer
--    category added to the registry is automatically covered, closing the
--    same class of gap for good.

SET app.current_entity='all';
SET app.current_realm='owner';

CREATE OR REPLACE VIEW v_uncategorised_summary AS
 SELECT date_trunc('month'::text, bt.transaction_date::timestamp with time zone)::date AS month,
    ba.account_name,
    bt.realm,
    count(*) AS n,
    sum(GREATEST(bt.amount, 0::numeric))::numeric(12,2) AS sum_in,
    sum(LEAST(bt.amount, 0::numeric))::numeric(12,2) AS sum_out
   FROM bank_transactions bt
     JOIN bank_accounts ba ON ba.id = bt.bank_account_id
  WHERE bt.category = 'needs_review'
  GROUP BY (date_trunc('month'::text, bt.transaction_date::timestamp with time zone)::date), ba.account_name, bt.realm
  ORDER BY (date_trunc('month'::text, bt.transaction_date::timestamp with time zone)::date) DESC, ba.account_name;

CREATE OR REPLACE VIEW v_account_transfers_open AS
 SELECT bt.id AS unmatched_txn_id,
    bt.transaction_date,
    bt.bank_account_id,
    ba.account_name,
    bt.amount,
    bt.description,
    bt.category,
    bt.realm
   FROM bank_transactions bt
     JOIN bank_accounts ba ON ba.id = bt.bank_account_id
  WHERE EXISTS (SELECT 1 FROM bank_category_registry r WHERE r.category = bt.category AND r.kind = 'transfer')
    AND NOT (EXISTS ( SELECT 1
           FROM account_transfers at
          WHERE at.src_txn_id = bt.id OR at.dst_txn_id = bt.id))
  ORDER BY bt.transaction_date DESC;
