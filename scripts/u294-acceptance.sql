-- scripts/u294-acceptance.sql
-- U294 Task 6 — acceptance cross-foot suite (coverage, kind cross-foot, balance
-- reconciliation, transfer legmatch net-to-zero). Read-only; safe to re-run any time.
--
-- Analytical dedup convention throughout: row_number() OVER (PARTITION BY
-- bank_account_id, transaction_date, amount, description ORDER BY id), rn=1 only.
--
-- Bars (see task brief + sprint-end amendments):
--   (a1) uncategorised (true NULL) = 0 rows                          -- PASS/FAIL printed
--   (a2) needs_review <= 15% of deduped £ volume                      -- reported as-is (sprint
--        accepted 16.3% honestly rather than gaming it further)
--   (b)  per-account 2026-monthly categorised movement == balance-implied
--        movement within £1, for accounts 3, 5, 15 (clean balance chains only)
--   (c)  transfer legmatch pairs net to ~0; Signal B (legmatch2) tagged 0 rows this
--        sprint (vacuous check, noted not failed) — check acctno signal's row count
--        (447) for presence of pairing activity instead.

SET app.current_entity='all';
SET app.current_realm='owner';

\echo '=== (a) Coverage by kind, deduped rows + £ volume ==='
WITH d AS (SELECT *, row_number() OVER (PARTITION BY bank_account_id,transaction_date,amount,description ORDER BY id) rn
             FROM bank_transactions)
SELECT coalesce(r.kind,'uncategorised') kind, count(*) rows,
       sum(abs(amount))::bigint vol,
       round(100.0*sum(abs(amount))/sum(sum(abs(amount))) OVER (),1) AS vol_pct
  FROM d LEFT JOIN bank_category_registry r ON r.category=d.category
 WHERE d.rn=1 GROUP BY 1 ORDER BY vol DESC;

\echo '=== (a1) True-NULL bar: uncategorised rows (bar: = 0) ==='
WITH d AS (SELECT *, row_number() OVER (PARTITION BY bank_account_id,transaction_date,amount,description ORDER BY id) rn
             FROM bank_transactions)
SELECT count(*) AS uncategorised_rows,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS verdict
  FROM d WHERE rn=1 AND category IS NULL;

\echo '=== (a2) needs_review bar: <= 15% of deduped Sigma|amount| (reported as-is) ==='
WITH d AS (SELECT *, row_number() OVER (PARTITION BY bank_account_id,transaction_date,amount,description ORDER BY id) rn
             FROM bank_transactions)
SELECT
  sum(CASE WHEN category='needs_review' THEN abs(amount) ELSE 0 END)::numeric(14,2) AS needs_review_vol,
  sum(abs(amount))::numeric(14,2) AS total_vol,
  round(100.0*sum(CASE WHEN category='needs_review' THEN abs(amount) ELSE 0 END)/sum(abs(amount)),1) AS needs_review_pct,
  CASE WHEN round(100.0*sum(CASE WHEN category='needs_review' THEN abs(amount) ELSE 0 END)/sum(abs(amount)),1) <= 15.0
       THEN 'PASS' ELSE 'FAIL (bar was <=15%; sprint accepted honestly, not forced)' END AS verdict
  FROM d WHERE rn=1;

\echo '=== (b) Per-account 2026-monthly: categorised movement (Sigma amount, deduped) vs balance-implied movement, accounts 3/5/15, tolerance £1 ==='
WITH d AS (
  SELECT *, row_number() OVER (PARTITION BY bank_account_id,transaction_date,amount,description ORDER BY id, id) rn
    FROM bank_transactions
   WHERE bank_account_id IN (3,5,15)
), dedup AS (SELECT * FROM d WHERE rn=1),
monthly_txn AS (
  SELECT bank_account_id, to_char(transaction_date,'YYYY-MM') ym,
         sum(amount)::numeric(14,2) AS txn_sum
    FROM dedup
   WHERE transaction_date >= '2026-01-01'
   GROUP BY 1,2
),
-- balance-implied movement = balance at the last txn of the month minus balance
-- at the last txn strictly before the month started (i.e. running-balance delta
-- across the month, ordered by date then id — matches recon-validate.py's method).
ordered AS (
  SELECT bank_account_id, transaction_date, id, balance,
         to_char(transaction_date,'YYYY-MM') ym
    FROM dedup
   WHERE balance IS NOT NULL
),
month_end AS (
  SELECT DISTINCT ON (bank_account_id, ym) bank_account_id, ym, balance AS end_balance, transaction_date
    FROM ordered
   ORDER BY bank_account_id, ym, transaction_date DESC, id DESC
),
month_start_prev AS (
  -- balance immediately before this month = the end_balance of the previous
  -- calendar month that has any balance rows (handles gaps).
  SELECT bank_account_id, ym,
         lag(end_balance) OVER (PARTITION BY bank_account_id ORDER BY ym) AS start_balance
    FROM month_end
)
SELECT t.bank_account_id, t.ym,
       t.txn_sum,
       (me.end_balance - msp.start_balance)::numeric(14,2) AS balance_delta,
       (t.txn_sum - (me.end_balance - msp.start_balance))::numeric(14,2) AS diff,
       CASE WHEN msp.start_balance IS NULL THEN 'n/a (no prior-month balance row)'
            WHEN abs(t.txn_sum - (me.end_balance - msp.start_balance)) <= 1.00 THEN 'PASS'
            ELSE 'FAIL — see report for cause' END AS verdict
  FROM monthly_txn t
  JOIN month_end me ON me.bank_account_id=t.bank_account_id AND me.ym=t.ym
  LEFT JOIN month_start_prev msp ON msp.bank_account_id=t.bank_account_id AND msp.ym=t.ym
 ORDER BY t.bank_account_id, t.ym;

\echo '=== (c) Transfer legmatch pairs net-to-zero, by pairing signal (deduped) ==='
SELECT category_source, count(*) AS rows, sum(amount)::numeric(14,2) AS net,
       sum(abs(amount))::numeric(14,2) AS sum_abs,
       CASE WHEN sum(abs(amount)) = 0 THEN 'VACUOUS (0 rows tagged this signal)'
            WHEN abs(sum(amount)) / sum(abs(amount)) < 0.02 THEN 'PASS (|net| < 2% of Sigma|abs|)'
            ELSE 'FAIL' END AS verdict
  FROM (SELECT *, row_number() OVER (PARTITION BY bank_account_id,transaction_date,amount,description ORDER BY id) rn
          FROM bank_transactions WHERE category_source LIKE 'u294:pairing%') d
 WHERE rn=1
 GROUP BY 1
 ORDER BY 1;

\echo '=== (c2) Presence check for the acctno signal (since legmatch2/Signal B tagged 0 rows and is vacuous) ==='
SELECT count(*) AS acctno_pairing_rows,
       CASE WHEN count(*) = 447 THEN 'MATCHES expected 447 (Task 2 result)' ELSE 'DIFFERS from expected 447 — investigate' END AS note
  FROM (SELECT *, row_number() OVER (PARTITION BY bank_account_id,transaction_date,amount,description ORDER BY id) rn
          FROM bank_transactions WHERE category_source = 'u294:pairing:acctno') d
 WHERE rn=1;
