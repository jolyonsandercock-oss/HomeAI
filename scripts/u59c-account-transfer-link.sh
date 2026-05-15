#!/usr/bin/env bash
#
# u59c-account-transfer-link.sh — pair-match bank_transactions rows that
# represent a transfer between two of Jo's accounts (credit-card payments,
# inter-entity moves, etc.) and write them to account_transfers.
#
# Matching rule (auto):
#   * one row's amount is the negation of another row's amount (±£0.05)
#   * |date_a - date_b| <= 2 days
#   * different bank_account_id
#   * source row is category IN ('inter_entity_transfer','transfer_uncategorised')
#   * partner is any uncategorised row OR also a transfer/uncat row
#   * exactly one candidate (unique pairing); ambiguous matches are skipped
#
# Idempotent: account_transfers has UNIQUE (src_txn_id, dst_txn_id) and we
# guard with NOT EXISTS so re-runs are no-ops.

set -euo pipefail

docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 <<'SQL'
SELECT set_config('app.current_entity', 'all',   false);
SELECT set_config('app.current_realm',  'owner', false);

-- ---------------------------------------------------------------------------
-- Pair-matching CTE:
--   * negative-side (money leaves)   → src
--   * positive-side (money arrives)  → dst
--   But for credit-card payments the sign convention is FLIPPED:
--     CC payment shows as -100 on the card (balance down) and
--     -100 on the NatWest current (money out).
--   So we also accept same-sign pairings on credit_card accounts.
-- ---------------------------------------------------------------------------

WITH candidate_pairs AS (
    SELECT
        a.id    AS a_id,
        b.id    AS b_id,
        a.amount AS a_amt,
        b.amount AS b_amt,
        a.transaction_date AS a_date,
        b.transaction_date AS b_date,
        a.bank_account_id AS a_acc,
        b.bank_account_id AS b_acc,
        a.realm,
        ABS(a.transaction_date - b.transaction_date) AS gap_days,
        CASE
            WHEN abs(a.amount + b.amount) <= 0.05 THEN 'opposite_sign'
            WHEN abs(a.amount - b.amount) <= 0.05
                 AND (ba.account_type = 'credit_card' OR bb.account_type = 'credit_card')
                 THEN 'cc_same_sign'
            ELSE NULL
        END AS shape
      FROM bank_transactions a
      JOIN bank_transactions b
        ON b.id > a.id   -- avoid (x,y) and (y,x) duplicates
       AND b.bank_account_id <> a.bank_account_id
       AND ABS(a.transaction_date - b.transaction_date) <= 2
      JOIN bank_accounts ba ON ba.id = a.bank_account_id
      JOIN bank_accounts bb ON bb.id = b.bank_account_id
     WHERE
        -- At least one side must be flagged transfer-like, OR both sides on
        -- accounts owned by Jo (entity 1,2,3,4 = all of them anyway).
        (a.category IN ('inter_entity_transfer','transfer_uncategorised')
            OR b.category IN ('inter_entity_transfer','transfer_uncategorised'))
        AND (abs(a.amount + b.amount) <= 0.05
             OR (abs(a.amount - b.amount) <= 0.05
                 AND (ba.account_type = 'credit_card' OR bb.account_type = 'credit_card')))
),
unique_pairs AS (
    -- Keep only pairs where neither side has another candidate that's just
    -- as close (gap_days <= this gap_days). Avoids accidental cross-matches
    -- between recurring identical-amount transfers in the same week.
    SELECT cp.*
      FROM candidate_pairs cp
     WHERE NOT EXISTS (
        SELECT 1 FROM candidate_pairs cp2
         WHERE (cp2.a_id = cp.a_id OR cp2.b_id = cp.a_id
             OR cp2.a_id = cp.b_id OR cp2.b_id = cp.b_id)
           AND (cp2.a_id, cp2.b_id) <> (cp.a_id, cp.b_id)
           AND cp2.gap_days <= cp.gap_days
     )
)
INSERT INTO account_transfers
    (src_txn_id, dst_txn_id, amount, transfer_date, realm,
     detection_method, confidence, notes)
SELECT
    -- src = the outflow side. Credit card "payment received" is amount<0 on
    -- the CC, but it's still the "destination" of money flow. Pick src by
    -- whichever row is on a non-credit_card account when one side is a card,
    -- otherwise by amount sign.
    CASE
        WHEN ba.account_type = 'credit_card' AND bb.account_type <> 'credit_card' THEN up.b_id
        WHEN bb.account_type = 'credit_card' AND ba.account_type <> 'credit_card' THEN up.a_id
        WHEN up.a_amt < 0 THEN up.a_id
        ELSE up.b_id
    END,
    CASE
        WHEN ba.account_type = 'credit_card' AND bb.account_type <> 'credit_card' THEN up.a_id
        WHEN bb.account_type = 'credit_card' AND ba.account_type <> 'credit_card' THEN up.b_id
        WHEN up.a_amt < 0 THEN up.b_id
        ELSE up.a_id
    END,
    ABS(up.a_amt),
    LEAST(up.a_date, up.b_date),
    up.realm,
    'amount_date_match',
    CASE
        WHEN up.gap_days = 0 THEN 0.98
        WHEN up.gap_days = 1 THEN 0.92
        ELSE 0.85
    END,
    'shape=' || up.shape || ' gap_days=' || up.gap_days
  FROM unique_pairs up
  JOIN bank_accounts ba ON ba.id = up.a_acc
  JOIN bank_accounts bb ON bb.id = up.b_acc
 WHERE NOT EXISTS (
    SELECT 1 FROM account_transfers at
     WHERE (at.src_txn_id = up.a_id AND at.dst_txn_id = up.b_id)
        OR (at.src_txn_id = up.b_id AND at.dst_txn_id = up.a_id)
 )
ON CONFLICT (src_txn_id, dst_txn_id) DO NOTHING;

\echo

-- Summary
SELECT
    'TOTAL linked' AS k,
    COUNT(*) AS n,
    SUM(amount)::numeric(12,2) AS total_value,
    MIN(transfer_date) AS dfirst,
    MAX(transfer_date) AS dlast
  FROM account_transfers;

\echo

SELECT
    src_ba.account_name AS from_acct,
    dst_ba.account_name AS to_acct,
    COUNT(*) AS n,
    SUM(at.amount)::numeric(12,2) AS total,
    ROUND(AVG(at.confidence)::numeric, 3) AS avg_conf
  FROM account_transfers at
  JOIN bank_transactions src_bt ON src_bt.id = at.src_txn_id
  JOIN bank_transactions dst_bt ON dst_bt.id = at.dst_txn_id
  JOIN bank_accounts src_ba ON src_ba.id = src_bt.bank_account_id
  JOIN bank_accounts dst_ba ON dst_ba.id = dst_bt.bank_account_id
 GROUP BY src_ba.account_name, dst_ba.account_name
 ORDER BY 3 DESC;

\echo

SELECT 'Still-open transfer-flagged rows (unpaired):' AS h, COUNT(*) AS n
  FROM v_account_transfers_open;
SQL
