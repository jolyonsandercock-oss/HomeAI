-- =============================================================================
-- V99 — Mortgage statement period coverage + gap view (U79)
-- =============================================================================
-- Every Principality statement covers one calendar quarter. To detect missing
-- statements, store one row per (loan_ref, period_start, period_end) we've
-- seen on a scan. Cross-reference against the quarters between earliest
-- observed period and (closed_date OR today) to flag gaps.
--
-- Seed comes from the four mortgage-statement scans (docs 19/20/21/22)
-- re-parsed forensically in U78.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

CREATE TABLE IF NOT EXISTS mortgage_statement_periods (
    id                  BIGSERIAL PRIMARY KEY,
    mortgage_account_id BIGINT NOT NULL REFERENCES mortgage_accounts(id) ON DELETE CASCADE,
    document_id         BIGINT REFERENCES documents(id),
    page_in_letter      INT,                       -- the "Page Number: N" Principality stamps
    period_start        DATE NOT NULL,
    period_end          DATE NOT NULL,
    balance_opening     NUMERIC(12,2),
    balance_closing     NUMERIC(12,2),
    interest_rate       NUMERIC(6,4),
    monthly_payment     NUMERIC(10,2),
    notes               TEXT,
    realm               TEXT NOT NULL DEFAULT 'work'
                          CHECK (realm IN ('owner','work','family','shared')),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (mortgage_account_id, period_start)
);
GRANT SELECT, INSERT, UPDATE ON mortgage_statement_periods TO homeai_pipeline;
GRANT USAGE, SELECT ON mortgage_statement_periods_id_seq TO homeai_pipeline;

ALTER TABLE mortgage_statement_periods ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS realm_isolation ON mortgage_statement_periods;
CREATE POLICY realm_isolation ON mortgage_statement_periods
    USING (CASE
        WHEN COALESCE(current_setting('app.current_realm', true), '') IN ('', 'owner') THEN TRUE
        ELSE realm = current_setting('app.current_realm', true)
    END);

-- ── Seed from doc 19/20/21/22 forensic extracts ────────────────────────────
INSERT INTO mortgage_statement_periods
    (mortgage_account_id, document_id, page_in_letter, period_start, period_end,
     balance_opening, balance_closing, notes, realm)
SELECT m.id, v.doc, v.pg, v.start::date, v.endd::date,
       v.bopen, v.bclose, v.note, 'work'
  FROM (VALUES
    -- doc 19: Q1 2025 / 295905-02
    ('295905-02', 19, 23, '2025-01-01', '2025-03-31', 180204.46, 177102.69, 'OCR doc 19. 8.3% rate effective 01/03/2025; £2,263.58 monthly.'),
    -- doc 20: three quarters of 295905-02
    ('295905-02', 20, 22, '2024-10-01', '2024-12-31', 183125.14, 180204.46, 'OCR doc 20.'),
    ('295905-02', 20, 21, '2024-07-02', '2024-09-30', 185982.97, 183125.14, 'OCR doc 20.'),
    ('295905-02', 20, 20, '2024-04-03', '2024-07-01', 188814.52, 185982.97, 'OCR doc 20.'),
    -- doc 21: three loans Q4 2019
    ('284512-03',  21, 42, '2019-10-01', '2019-12-31', 201058.22, 201058.22, 'OCR doc 21. Interest only — principal frozen.'),
    ('289751-04',  21, 30, '2019-10-01', '2019-12-31', 189123.50, 186565.79, 'OCR doc 21.'),
    ('295905-02',  21,  4, '2019-10-01', '2019-12-31', 100000.00, 100000.00, 'OCR doc 21. Was INTEREST ONLY at this date.'),
    -- doc 22: three loans Q3 2021
    ('295905-02',  22,  9, '2021-07-01', '2021-09-30', 220025.12, 217004.46, 'OCR doc 22. Still INTEREST ONLY.'),
    ('289759-10',  22, 35, '2021-07-01', '2021-09-30',      2.31,  63010.34, 'OCR doc 22. Drawdown quarter.'),
    ('284512-03',  22, 47, '2021-07-01', '2021-09-30', 201058.22, 201058.22, 'OCR doc 22. Principal frozen.')
  ) AS v (loan_ref, doc, pg, start, endd, bopen, bclose, note)
  JOIN mortgage_accounts m ON m.account_ref = v.loan_ref
ON CONFLICT (mortgage_account_id, period_start) DO NOTHING;

-- ── Gap view: per active loan, list quarters covered + quarters missing ───
CREATE OR REPLACE VIEW v_mortgage_coverage AS
WITH
quarters AS (
    -- Generate every quarter start since 2019-01-01 to current quarter
    SELECT date_trunc('quarter', d)::date AS q_start,
           (date_trunc('quarter', d) + interval '3 months - 1 day')::date AS q_end
      FROM generate_series('2019-01-01'::date, current_date, '3 months'::interval) d
),
loan_quarters AS (
    -- For each loan, generate the quarters we'd expect: earliest_seen → closed_date OR today.
    -- For loans with no scans, expected range is empty (we don't know origination).
    SELECT m.id AS loan_id,
           m.account_ref,
           m.closed_date,
           COALESCE(
               (SELECT min(period_start) FROM mortgage_statement_periods sp WHERE sp.mortgage_account_id=m.id),
               m.balance_as_of
           ) AS first_seen,
           COALESCE(m.closed_date, current_date) AS coverage_end
      FROM mortgage_accounts m
),
expected AS (
    SELECT lq.loan_id, lq.account_ref, q.q_start, q.q_end
      FROM loan_quarters lq
      JOIN quarters q
        ON q.q_start >= lq.first_seen
       AND q.q_start <  lq.coverage_end
     WHERE lq.first_seen IS NOT NULL
)
SELECT
    m.id                  AS loan_id,
    m.account_ref,
    m.closed_date IS NULL AS active,
    (SELECT count(*) FROM mortgage_statement_periods sp WHERE sp.mortgage_account_id=m.id) AS scans_on_file,
    (SELECT count(*) FROM expected e WHERE e.loan_id=m.id)::int AS quarters_expected,
    (SELECT count(*) FROM expected e
      WHERE e.loan_id=m.id
        AND NOT EXISTS (SELECT 1 FROM mortgage_statement_periods sp
                         WHERE sp.mortgage_account_id=m.id
                           AND sp.period_start = e.q_start))::int AS quarters_missing,
    (SELECT array_agg(to_char(e.q_start, 'YYYY-MM') ORDER BY e.q_start)
       FROM expected e
      WHERE e.loan_id=m.id
        AND NOT EXISTS (SELECT 1 FROM mortgage_statement_periods sp
                         WHERE sp.mortgage_account_id=m.id
                           AND sp.period_start = e.q_start)) AS missing_quarters
  FROM mortgage_accounts m
 ORDER BY m.closed_date IS NULL DESC, m.account_ref;

GRANT SELECT ON v_mortgage_coverage TO homeai_pipeline;

-- ── Slug ────────────────────────────────────────────────────────────────────
INSERT INTO query_whitelist
    (slug, display_name, description, intent_examples, sql_template, param_schema,
     result_format, active, entity_id, created_by, approved_at, approved_by, realm)
SELECT 'mortgage_coverage', 'Statement coverage',
       'Quarters scanned vs quarters expected per mortgage account; flags missing statement periods.',
       ARRAY['mortgage coverage','missing statements','statement gaps']::text[],
       'SELECT account_ref, active, scans_on_file, quarters_expected, quarters_missing, missing_quarters FROM v_mortgage_coverage',
       '{}'::jsonb, 'table', true, 3, 'u79', now(), 'u79', 'owner'
WHERE NOT EXISTS (SELECT 1 FROM query_whitelist WHERE slug='mortgage_coverage');

COMMIT;
