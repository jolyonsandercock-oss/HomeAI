#!/usr/bin/env bash
#
# u58-bank-tx-categorise.sh — apply bank_transaction_rules to uncategorised
# bank_transactions. Idempotent: only touches rows where category IS NULL.
#
# Each rule is evaluated in priority order. The first rule that matches wins.
# Rules are POSIX regex (description) + optional Type filter + optional
# amount comparator + optional entity filter.
#
# Stats printed at end: rows tagged per category + remaining uncategorised.
# A second pass with --reset clears categories below confidence_threshold so
# you can re-seed after editing rules.

set -euo pipefail

RESET="${1:-}"

docker exec homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 <<SQL
\set ON_ERROR_STOP on

-- Per AGENTS.md SQL discipline:
SELECT set_config('app.current_entity', 'all',   false);
SELECT set_config('app.current_realm',  'owner', false);

$(if [[ "$RESET" == "--reset" ]]; then
    echo "UPDATE bank_transactions SET category=NULL, category_confidence=NULL, category_source=NULL"
    echo " WHERE category_source LIKE 'rule:%';"
fi)

-- Apply rules to uncategorised rows. The DO block iterates rules in priority
-- order; UPDATE skips rows already tagged earlier in the loop.
DO \$\$
DECLARE
    r RECORD;
    affected INT;
    total_applied INT := 0;
BEGIN
    FOR r IN
        SELECT * FROM bank_transaction_rules ORDER BY priority, id
    LOOP
        EXECUTE format(\$dyn\$
          UPDATE bank_transactions bt
             SET category            = %L,
                 category_confidence = %s,
                 category_source     = 'rule:' || %L
            FROM bank_accounts ba
           WHERE ba.id = bt.bank_account_id
             AND bt.category IS NULL
             %s   -- description regex
             %s   -- type IN filter
             %s   -- amount comparator
             %s   -- entity IN filter
        \$dyn\$,
            r.category,
            r.confidence::text,
            r.name,
            CASE WHEN r.description_re IS NOT NULL
                 THEN format('AND bt.description ~* %L', r.description_re)
                 ELSE '' END,
            CASE WHEN r.type_in IS NOT NULL
                 THEN format('AND split_part(bt.description, '' '', 1) = ANY(%L::text[]) OR upper(left(bt.description, 4)) = ANY(ARRAY[%s])',
                             r.type_in,
                             (SELECT string_agg(quote_literal(upper(t)), ',') FROM unnest(r.type_in) AS t))
                 ELSE '' END,
            CASE WHEN r.amount_op IS NOT NULL AND r.amount_value IS NOT NULL
                 THEN format('AND bt.amount %s %s', r.amount_op, r.amount_value::text)
                 ELSE '' END,
            CASE WHEN r.entity_in IS NOT NULL
                 THEN format('AND bt.entity_id = ANY(%L::int[])', r.entity_in)
                 ELSE '' END
        );
        GET DIAGNOSTICS affected = ROW_COUNT;
        IF affected > 0 THEN
            RAISE NOTICE 'rule % priority=% applied to % row(s)', r.name, r.priority, affected;
            total_applied := total_applied + affected;
        END IF;
    END LOOP;
    RAISE NOTICE 'total rows categorised this run: %', total_applied;
END
\$\$;

-- Summary
SELECT 'CATEGORISED' AS section, COUNT(*) AS n FROM bank_transactions WHERE category IS NOT NULL
UNION ALL
SELECT 'UNCATEGORISED', COUNT(*) FROM bank_transactions WHERE category IS NULL;

SELECT category, COUNT(*) AS n, ROUND(AVG(category_confidence)::numeric, 3) AS avg_conf
  FROM bank_transactions WHERE category IS NOT NULL
 GROUP BY category ORDER BY 2 DESC;

SELECT 'UNCATEGORISED-SAMPLE (look here to add rules):' AS hint;
SELECT bt.transaction_date, split_part(bt.description, ',', 1) AS d_head, ba.account_name, bt.amount
  FROM bank_transactions bt JOIN bank_accounts ba ON ba.id = bt.bank_account_id
 WHERE bt.category IS NULL
 ORDER BY bt.transaction_date DESC LIMIT 15;
SQL
