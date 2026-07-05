-- scripts/u294-transfer-pairing.sql — deterministic own-account transfer detection.
-- Two independent signals, applied in order; idempotent (category IS NULL guard).
\set ON_ERROR_STOP on
SELECT set_config('app.current_entity','all',false);
SELECT set_config('app.current_realm','owner',false);

BEGIN;
CREATE TABLE IF NOT EXISTS _backup_u294_task2 AS
  SELECT id, category, category_source FROM bank_transactions WHERE false;

-- Signal A: description names one of OUR account numbers -> transfer, and
-- card accounts on the other side -> card_repayment.
WITH tagged AS (
  SELECT bt.id,
         CASE WHEN a_other.account_type ILIKE '%card%'
               OR a_other.account_name ILIKE '%mastercard%'
               OR a_other.account_name ILIKE '%cap on tap%'
              THEN 'card_repayment' ELSE 'internal_transfer' END AS newcat
    FROM bank_transactions bt
    JOIN bank_accounts a_other
      ON a_other.id <> bt.bank_account_id
     AND length(coalesce(a_other.account_number,'')) >= 8
     AND bt.description LIKE '%'||a_other.account_number||'%'
   WHERE bt.category IS NULL
), bk AS (
  INSERT INTO _backup_u294_task2
  SELECT b.id, b.category, b.category_source FROM bank_transactions b JOIN tagged t ON t.id=b.id
  RETURNING 1
)
UPDATE bank_transactions bt
   SET category=t.newcat, category_confidence=0.95, category_source='u294:pairing:acctno'
  FROM tagged t WHERE bt.id=t.id;

-- Signal B: opposite-amount pair between two own accounts within 3 days,
-- both still NULL, description carries a transfer phrase on at least one leg.
WITH pairs AS (
  SELECT o.id AS out_id, i.id AS in_id
    FROM bank_transactions o
    JOIN bank_transactions i
      ON i.amount = -o.amount AND o.amount < 0
     AND i.bank_account_id <> o.bank_account_id
     AND i.transaction_date BETWEEN o.transaction_date AND o.transaction_date + 3
   WHERE o.category IS NULL AND i.category IS NULL
     AND (o.description ~* 'TO A/C|VIA MOBILE|MOBILE/ONLINE|ONLINE TRANSACTION'
          OR i.description ~* 'FROM A/C|VIA MOBILE|MOBILE/ONLINE|AUTOMATED CREDIT')
), ids AS (
  SELECT out_id AS id FROM pairs UNION SELECT in_id FROM pairs
), bk AS (
  INSERT INTO _backup_u294_task2
  SELECT b.id, b.category, b.category_source FROM bank_transactions b JOIN ids ON ids.id=b.id
  RETURNING 1
)
UPDATE bank_transactions bt
   SET category='internal_transfer', category_confidence=0.85, category_source='u294:pairing:legmatch'
  FROM ids WHERE bt.id=ids.id;

-- Cross-foot: transfers must roughly net to zero on deduped legmatch pairs.
SELECT category_source, count(*), sum(amount)::numeric(14,2) AS net
  FROM (SELECT *, row_number() OVER (PARTITION BY bank_account_id,transaction_date,amount,description ORDER BY id) rn
          FROM bank_transactions WHERE category_source LIKE 'u294:pairing%') d
 WHERE rn=1 GROUP BY 1;
COMMIT;
