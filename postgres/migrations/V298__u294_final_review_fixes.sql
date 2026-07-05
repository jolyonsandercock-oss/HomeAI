-- V298 (2026-07-05) — U294 final whole-branch review: three blockers.
--
-- B1) v_uncategorised_summary blind to future NULLs. V297 fixed the view's
--     stale `category IS NULL` predicate by switching it to
--     `category = 'needs_review'` on the (correct, at the time) assumption
--     that Task 5's residual sweep left true NULL at 0 rows forever. But new
--     imports land with category IS NULL and stay NULL until either a rule
--     matches or a future sweep runs — those rows are invisible to the
--     review surface again, the same V293 silent-omission class the view
--     exists to prevent. Widened the predicate to catch both states.
--     CREATE OR REPLACE, every other part of the V297 definition kept
--     byte-for-byte identical (confirmed live via pg_get_viewdef before
--     editing).
--
-- B2) See scripts/u294-needs-review-sweep.sql (companion script, not part of
--     this migration) — records the one-shot residual sweep that tagged
--     11,110 rows category_source='u294:residual-sweep' with no committed
--     artifact behind it.
--
-- B3) Rule priority inversion: priority 110 ('YouLend remit (card takings)',
--     regex 'YOULEND|YL LIMITED', amount>0 -> income_trading) fires before
--     priority 135 ('YouLend II funding advance', regex
--     'YL II A LIMITED|FUNDING FOR ADVANC', amount>0 -> financing_advance).
--     'YL II A LIMITED' narratives also contain the substring 'YL' and would
--     be caught by rule 110's broader OR-branch first were it not for u58's
--     priority-ordered DO loop skipping already-categorised rows — so a
--     future advance narrating both patterns is one accidental rule-order
--     change away from being booked as trading income instead of a loan
--     drawdown. Promoted the financing_advance rule to priority 105 (above
--     110) so it wins the race unconditionally. Rule matched live on its
--     description_re ('YL II A LIMITED|FUNDING FOR ADVANC') + name, not by
--     assumed id.

SET app.current_entity='all';
SET app.current_realm='owner';

-- B1 -------------------------------------------------------------------
CREATE OR REPLACE VIEW v_uncategorised_summary AS
 SELECT date_trunc('month'::text, bt.transaction_date::timestamp with time zone)::date AS month,
    ba.account_name,
    bt.realm,
    count(*) AS n,
    sum(GREATEST(bt.amount, 0::numeric))::numeric(12,2) AS sum_in,
    sum(LEAST(bt.amount, 0::numeric))::numeric(12,2) AS sum_out
   FROM bank_transactions bt
     JOIN bank_accounts ba ON ba.id = bt.bank_account_id
  WHERE (bt.category = 'needs_review'::text OR bt.category IS NULL)
  GROUP BY (date_trunc('month'::text, bt.transaction_date::timestamp with time zone)::date), ba.account_name, bt.realm
  ORDER BY (date_trunc('month'::text, bt.transaction_date::timestamp with time zone)::date) DESC, ba.account_name;

COMMENT ON VIEW v_uncategorised_summary IS
  'Review queue: needs_review + true NULL. Future NULLs (new imports, not yet '
  'rule-matched or swept) MUST surface here — this is the same V293 '
  'silent-omission class; do not narrow the predicate back to a single '
  'sentinel value. V298 2026-07-05, final-review B1.';

-- B3 -------------------------------------------------------------------
UPDATE bank_transaction_rules
   SET priority = 105,
       notes = notes || ' ; promoted above YouLend remit rule 2026-07-05, final-review B3'
 WHERE description_re = 'YL II A LIMITED|FUNDING FOR ADVANC'
   AND name = 'YouLend II funding advance'
   AND category = 'financing_advance';
