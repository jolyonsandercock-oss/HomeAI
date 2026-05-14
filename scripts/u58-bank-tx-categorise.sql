-- u58-bank-tx-categorise.sql — apply bank_transaction_rules to uncategorised
-- bank_transactions. Idempotent: only touches rows where category IS NULL.

\set ON_ERROR_STOP on

-- Per AGENTS.md SQL discipline:
SELECT set_config('app.current_entity', 'all',   false);
SELECT set_config('app.current_realm',  'owner', false);

DO $$
DECLARE
    r RECORD;
    sql_text TEXT;
    affected INT;
    total_applied INT := 0;
BEGIN
    FOR r IN
        SELECT id, priority, name, description_re, type_in, amount_op,
               amount_value, entity_in, category, confidence
          FROM bank_transaction_rules
         ORDER BY priority, id
    LOOP
        sql_text := format($f$
          UPDATE bank_transactions bt
             SET category            = %L,
                 category_confidence = %L,
                 category_source     = %L
           WHERE bt.category IS NULL
        $f$, r.category, r.confidence, 'rule:' || r.name);

        IF r.description_re IS NOT NULL THEN
            sql_text := sql_text || format(' AND bt.description ~* %L', r.description_re);
        END IF;

        -- Match Type by comparing the first comma-separated token to the
        -- type_in array. NatWest CSV puts Type as the second CSV column
        -- which we imported into description column verbatim? No — we
        -- imported just the Description column. The Type is gone. So
        -- skip type_in for now; rules with type_in alone will be too
        -- permissive but we'll tighten in Phase B.
        IF r.amount_op IS NOT NULL AND r.amount_value IS NOT NULL THEN
            sql_text := sql_text || format(' AND bt.amount %s %s',
                            r.amount_op, r.amount_value::text);
        END IF;

        IF r.entity_in IS NOT NULL THEN
            sql_text := sql_text || format(' AND bt.entity_id = ANY(%L::int[])', r.entity_in);
        END IF;

        EXECUTE sql_text;
        GET DIAGNOSTICS affected = ROW_COUNT;
        IF affected > 0 THEN
            RAISE NOTICE 'rule % priority=% applied to % row(s)',
                r.name, r.priority, affected;
            total_applied := total_applied + affected;
        END IF;
    END LOOP;
    RAISE NOTICE 'total rows categorised this run: %', total_applied;
END
$$;

-- Summary
SELECT 'CATEGORISED' AS section, COUNT(*) AS n
  FROM bank_transactions WHERE category IS NOT NULL
UNION ALL
SELECT 'UNCATEGORISED', COUNT(*)
  FROM bank_transactions WHERE category IS NULL;

SELECT category, COUNT(*) AS n, ROUND(AVG(category_confidence)::numeric, 3) AS avg_conf
  FROM bank_transactions WHERE category IS NOT NULL
 GROUP BY category ORDER BY 2 DESC;

\echo
\echo 'UNCATEGORISED SAMPLE — adjust rules to catch these:'
SELECT bt.transaction_date,
       LEFT(bt.description, 60) AS d_head,
       ba.account_name,
       bt.amount
  FROM bank_transactions bt
  JOIN bank_accounts ba ON ba.id = bt.bank_account_id
 WHERE bt.category IS NULL
 ORDER BY bt.transaction_date DESC LIMIT 15;
