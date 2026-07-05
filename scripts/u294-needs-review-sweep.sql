-- scripts/u294-needs-review-sweep.sql — U294 final-review B2.
--
-- Reproduces, as a committed artifact, the one-shot residual sweep that was
-- applied live 2026-07-05 (T5 round 4): 11,110 rows tagged
-- category_source='u294:residual-sweep' with no script behind them until
-- now. Idempotent and safe to re-run anytime — it only ever touches rows
-- where category IS NULL, so a clean run after the live sweep already
-- happened is a correct no-op (0 rows), not a bug.
--
-- Pre-images of every row this script is about to touch are archived to
-- _backup_u294_task5_sweep (id, category, category_source — matches the
-- shape of the existing backup table created by the live 2026-07-05 run) so
-- the sweep can be rolled back with a plain UPDATE ... FROM the backup.
--
-- Usage: docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 < scripts/u294-needs-review-sweep.sql

\set ON_ERROR_STOP on

SELECT set_config('app.current_entity', 'all',   false);
SELECT set_config('app.current_realm',  'owner', false);

CREATE TABLE IF NOT EXISTS _backup_u294_task5_sweep (
    id               bigint,
    category         text,
    category_source  text
);

-- Single statement: both CTEs read the pre-touch snapshot (category IS NULL),
-- so the backup and the update act on exactly the same row set even though
-- the UPDATE overwrites category in the live table.
WITH backed_up AS (
    INSERT INTO _backup_u294_task5_sweep (id, category, category_source)
    SELECT id, category, category_source
      FROM bank_transactions
     WHERE category IS NULL
    RETURNING 1
),
touched AS (
    UPDATE bank_transactions
       SET category            = 'needs_review',
           category_confidence = 0,
           category_source     = 'u294:residual-sweep'
     WHERE category IS NULL
    RETURNING 1
)
SELECT (SELECT COUNT(*) FROM backed_up) AS rows_backed_up_this_run,
       (SELECT COUNT(*) FROM touched)   AS rows_updated_this_run,
       'OPS_ROWS=' || (SELECT COUNT(*) FROM touched) AS ops_rows_line;

-- Sanity: total rows ever tagged by the sweep (live run + this run), for the
-- human reading the log.
SELECT 'total tagged u294:residual-sweep to date' AS metric, COUNT(*) AS n
  FROM bank_transactions
 WHERE category_source = 'u294:residual-sweep';
