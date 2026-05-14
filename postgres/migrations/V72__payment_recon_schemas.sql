-- =============================================================================
-- V72 — Payment Reconciliation & Cash Surveillance schema (Phase 1 of PART 4b)
-- =============================================================================
-- Creates raw / staging / mart schemas + every table in SPEC.md §4b.3 + the
-- current-month partition for every partitioned table.
--
-- Existing public.* payment-related tables (public.bank_transactions,
-- public.dojo_transactions, public.touchoffice_*, public.caterbook_*) are
-- LEFT UNTOUCHED — they're the v5.x legacy pattern grandfathered by §4b.0
-- with a non-blocking migration ticket queued.
--
-- Idempotent: re-running is a no-op (every CREATE uses IF NOT EXISTS;
-- partition creation guarded by pg_class lookup).
-- =============================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS mart;

GRANT USAGE ON SCHEMA raw, staging, mart TO homeai_pipeline;
GRANT USAGE ON SCHEMA raw, staging, mart TO homeai_readonly;

-- -----------------------------------------------------------------------------
-- raw.imports — file-level idempotency
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS raw.imports (
    id              BIGSERIAL PRIMARY KEY,
    source          TEXT        NOT NULL,
    adapter         TEXT        NOT NULL CHECK (adapter IN ('api','scrape','csv')),
    file_sha256     TEXT        NOT NULL,
    payload_path    TEXT        NOT NULL,
    manifest_json   JSONB       NOT NULL,
    captured_at     TIMESTAMPTZ NOT NULL,
    imported_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    row_count       INTEGER     NOT NULL,
    operator        TEXT        NOT NULL,
    realm           TEXT        NOT NULL DEFAULT 'work'
                                  CHECK (realm IN ('owner','work','family','shared')),
    UNIQUE (source, file_sha256)
);
CREATE INDEX IF NOT EXISTS idx_raw_imports_source_captured
    ON raw.imports (source, captured_at DESC);

-- -----------------------------------------------------------------------------
-- raw.dojo_transactions
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS raw.dojo_transactions (
    id                       BIGSERIAL,
    source                   TEXT        NOT NULL DEFAULT 'dojo',
    source_transaction_id    TEXT        NOT NULL,
    row_hash                 TEXT        NOT NULL,
    first_seen_via           TEXT        NOT NULL CHECK (first_seen_via IN ('api','scrape','csv')),
    import_id                BIGINT      NOT NULL REFERENCES raw.imports(id),
    transaction_date         DATE        NOT NULL,
    transaction_at_utc       TIMESTAMPTZ NOT NULL,
    terminal_id              TEXT        NOT NULL,
    site                     TEXT        NOT NULL,
    entry_mode               TEXT,
    amount_minor             BIGINT      NOT NULL,
    gratuity_minor           BIGINT,
    fee_minor                BIGINT,
    refund_of                TEXT,
    outcome                  TEXT        NOT NULL,
    last4_pan                TEXT,
    auth_code                TEXT,
    settlement_batch_id      TEXT,
    raw_payload              JSONB       NOT NULL,
    realm                    TEXT        NOT NULL DEFAULT 'work'
                                          CHECK (realm IN ('owner','work','family','shared')),
    PRIMARY KEY (id, transaction_date),
    UNIQUE (source, source_transaction_id, transaction_date)
) PARTITION BY RANGE (transaction_date);

CREATE INDEX IF NOT EXISTS idx_dojo_entry_mode_risk
    ON raw.dojo_transactions (entry_mode, transaction_date DESC)
    WHERE entry_mode IN ('keyed','vt');
CREATE INDEX IF NOT EXISTS idx_dojo_terminal_date
    ON raw.dojo_transactions (terminal_id, transaction_date DESC);
CREATE INDEX IF NOT EXISTS idx_dojo_settlement
    ON raw.dojo_transactions (settlement_batch_id)
    WHERE settlement_batch_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- raw.clover_transactions
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS raw.clover_transactions (
    id                       BIGSERIAL,
    source                   TEXT        NOT NULL DEFAULT 'clover',
    source_transaction_id    TEXT        NOT NULL,
    row_hash                 TEXT        NOT NULL,
    first_seen_via           TEXT        NOT NULL CHECK (first_seen_via IN ('api','scrape','csv')),
    import_id                BIGINT      NOT NULL REFERENCES raw.imports(id),
    transaction_date         DATE        NOT NULL,
    transaction_at_utc       TIMESTAMPTZ NOT NULL,
    merchant_id              TEXT        NOT NULL,
    device_id                TEXT,
    entry_mode               TEXT        NOT NULL,
    amount_minor             BIGINT      NOT NULL,
    fee_minor                BIGINT,
    refund_of                TEXT,
    outcome                  TEXT        NOT NULL,
    last4_pan                TEXT,
    auth_code                TEXT,
    customer_reference       TEXT,
    settlement_batch_id      TEXT,
    raw_payload              JSONB       NOT NULL,
    realm                    TEXT        NOT NULL DEFAULT 'work'
                                          CHECK (realm IN ('owner','work','family','shared')),
    PRIMARY KEY (id, transaction_date),
    UNIQUE (source, source_transaction_id, transaction_date)
) PARTITION BY RANGE (transaction_date);

CREATE INDEX IF NOT EXISTS idx_clover_entry_mode_risk
    ON raw.clover_transactions (entry_mode, transaction_date DESC)
    WHERE entry_mode IN ('keyed','vt');

-- -----------------------------------------------------------------------------
-- raw.touchoffice_orders
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS raw.touchoffice_orders (
    id                       BIGSERIAL,
    source                   TEXT        NOT NULL DEFAULT 'touchoffice',
    source_transaction_id    TEXT        NOT NULL,
    row_hash                 TEXT        NOT NULL,
    first_seen_via           TEXT        NOT NULL CHECK (first_seen_via IN ('api','scrape','csv')),
    import_id                BIGINT      NOT NULL REFERENCES raw.imports(id),
    transaction_date         DATE        NOT NULL,
    closed_at_utc            TIMESTAMPTZ NOT NULL,
    site                     TEXT        NOT NULL,
    till_id                  TEXT,
    operator_id              TEXT        NOT NULL,
    operator_name            TEXT,
    department               TEXT,
    tender_breakdown         JSONB       NOT NULL,
    total_gross_minor        BIGINT      NOT NULL,
    total_net_minor          BIGINT      NOT NULL,
    voids_minor              BIGINT      NOT NULL DEFAULT 0,
    refunds_minor            BIGINT      NOT NULL DEFAULT 0,
    discounts_minor          BIGINT      NOT NULL DEFAULT 0,
    comps_minor              BIGINT      NOT NULL DEFAULT 0,
    last4_pan                TEXT,
    terminal_ref             TEXT,
    raw_payload              JSONB       NOT NULL,
    realm                    TEXT        NOT NULL DEFAULT 'work'
                                          CHECK (realm IN ('owner','work','family','shared')),
    PRIMARY KEY (id, transaction_date),
    UNIQUE (source, source_transaction_id, transaction_date)
) PARTITION BY RANGE (transaction_date);

CREATE INDEX IF NOT EXISTS idx_to_orders_site_date
    ON raw.touchoffice_orders (site, transaction_date DESC);
CREATE INDEX IF NOT EXISTS idx_to_orders_operator
    ON raw.touchoffice_orders (operator_id, transaction_date DESC);
CREATE INDEX IF NOT EXISTS idx_to_orders_refund_void
    ON raw.touchoffice_orders (transaction_date DESC)
    WHERE refunds_minor > 0 OR voids_minor > 0;

-- -----------------------------------------------------------------------------
-- raw.bank_lines
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS raw.bank_lines (
    id                       BIGSERIAL,
    source                   TEXT        NOT NULL,
    source_transaction_id    TEXT        NOT NULL,
    row_hash                 TEXT        NOT NULL,
    first_seen_via           TEXT        NOT NULL CHECK (first_seen_via IN ('api','scrape','csv')),
    import_id                BIGINT      NOT NULL REFERENCES raw.imports(id),
    transaction_date         DATE        NOT NULL,
    posted_at_utc            TIMESTAMPTZ,
    account_ref              TEXT        NOT NULL,
    type_code                TEXT,
    description              TEXT        NOT NULL,
    amount_minor             BIGINT      NOT NULL,
    balance_after_minor      BIGINT,
    counterparty_name        TEXT,
    counterparty_ref         TEXT,
    raw_payload              JSONB       NOT NULL,
    realm                    TEXT        NOT NULL DEFAULT 'work'
                                          CHECK (realm IN ('owner','work','family','shared')),
    entity_id                INTEGER REFERENCES entities(id),
    PRIMARY KEY (id, transaction_date),
    UNIQUE (source, source_transaction_id, transaction_date)
) PARTITION BY RANGE (transaction_date);

CREATE INDEX IF NOT EXISTS idx_bank_lines_account_date
    ON raw.bank_lines (account_ref, transaction_date DESC);
CREATE INDEX IF NOT EXISTS idx_bank_lines_entity_date
    ON raw.bank_lines (entity_id, transaction_date DESC);

-- -----------------------------------------------------------------------------
-- raw.caterbook_reservations
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS raw.caterbook_reservations (
    id                       BIGSERIAL,
    source                   TEXT        NOT NULL DEFAULT 'caterbook',
    source_transaction_id    TEXT        NOT NULL,
    row_hash                 TEXT        NOT NULL,
    first_seen_via           TEXT        NOT NULL CHECK (first_seen_via IN ('api','scrape','csv')),
    import_id                BIGINT      NOT NULL REFERENCES raw.imports(id),
    reservation_id           TEXT        NOT NULL,
    arrival_date             DATE        NOT NULL,
    departure_date           DATE        NOT NULL,
    booking_date             DATE        NOT NULL,
    guest_name               TEXT,
    room_ref                 TEXT,
    rate_code                TEXT,
    nights                   INTEGER     NOT NULL,
    total_minor              BIGINT      NOT NULL,
    deposit_minor            BIGINT,
    payment_method           TEXT,
    payment_processor        TEXT,
    payment_reference        TEXT,
    status                   TEXT        NOT NULL,
    raw_payload              JSONB       NOT NULL,
    realm                    TEXT        NOT NULL DEFAULT 'work'
                                          CHECK (realm IN ('owner','work','family','shared')),
    PRIMARY KEY (id, arrival_date),
    UNIQUE (source, source_transaction_id, arrival_date)
) PARTITION BY RANGE (arrival_date);

-- -----------------------------------------------------------------------------
-- staging.payments
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS staging.payments (
    id                       BIGSERIAL,
    raw_table                TEXT        NOT NULL,
    raw_id                   BIGINT      NOT NULL,
    source                   TEXT        NOT NULL,
    source_transaction_id    TEXT        NOT NULL,
    transaction_date         DATE        NOT NULL,
    transaction_at_utc       TIMESTAMPTZ NOT NULL,
    site                     TEXT        NOT NULL,
    terminal_id              TEXT,
    entry_mode               TEXT,
    amount_gross_minor       BIGINT      NOT NULL,
    fee_minor                BIGINT,
    amount_net_minor         BIGINT      NOT NULL,
    outcome                  TEXT        NOT NULL,
    refund_of                TEXT,
    last4_pan                TEXT,
    settlement_batch_id      TEXT,
    is_elevated_risk         BOOLEAN     NOT NULL DEFAULT FALSE,
    staged_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    realm                    TEXT        NOT NULL DEFAULT 'work'
                                          CHECK (realm IN ('owner','work','family','shared')),
    PRIMARY KEY (id, transaction_date),
    UNIQUE (source, source_transaction_id, transaction_date)
) PARTITION BY RANGE (transaction_date);

CREATE INDEX IF NOT EXISTS idx_stg_payments_site_date
    ON staging.payments (site, transaction_date DESC);
CREATE INDEX IF NOT EXISTS idx_stg_payments_settle
    ON staging.payments (settlement_batch_id)
    WHERE settlement_batch_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_stg_payments_elevated
    ON staging.payments (transaction_date DESC)
    WHERE is_elevated_risk;

-- -----------------------------------------------------------------------------
-- staging.bank_lines
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS staging.bank_lines (
    id                       BIGSERIAL,
    raw_id                   BIGINT      NOT NULL,
    source                   TEXT        NOT NULL,
    source_transaction_id    TEXT        NOT NULL,
    transaction_date         DATE        NOT NULL,
    account_ref              TEXT        NOT NULL,
    entity_id                INTEGER REFERENCES entities(id),
    type_code                TEXT,
    description              TEXT        NOT NULL,
    amount_minor             BIGINT      NOT NULL,
    counterparty_name        TEXT,
    counterparty_ref         TEXT,
    is_settlement_candidate  BOOLEAN     NOT NULL DEFAULT FALSE,
    is_fee                   BOOLEAN     NOT NULL DEFAULT FALSE,
    staged_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    realm                    TEXT        NOT NULL DEFAULT 'work'
                                          CHECK (realm IN ('owner','work','family','shared')),
    PRIMARY KEY (id, transaction_date),
    UNIQUE (source, source_transaction_id, transaction_date)
) PARTITION BY RANGE (transaction_date);

CREATE INDEX IF NOT EXISTS idx_stg_bank_account_date
    ON staging.bank_lines (account_ref, transaction_date DESC);
CREATE INDEX IF NOT EXISTS idx_stg_bank_settle_cand
    ON staging.bank_lines (transaction_date DESC)
    WHERE is_settlement_candidate;

-- -----------------------------------------------------------------------------
-- mart.daily_totals
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS mart.daily_totals (
    id                       BIGSERIAL,
    transaction_date         DATE        NOT NULL,
    site                     TEXT        NOT NULL,
    tender                   TEXT        NOT NULL,
    pos_total_minor          BIGINT,
    processor_total_minor    BIGINT,
    cash_declared_minor      BIGINT,
    delta_minor              BIGINT,
    tolerance_minor          BIGINT      NOT NULL,
    status                   TEXT        NOT NULL,
    notes                    TEXT,
    computed_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    realm                    TEXT        NOT NULL DEFAULT 'work'
                                          CHECK (realm IN ('owner','work','family','shared')),
    PRIMARY KEY (id, transaction_date),
    UNIQUE (transaction_date, site, tender)
) PARTITION BY RANGE (transaction_date);

-- -----------------------------------------------------------------------------
-- mart.transaction_matches
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS mart.transaction_matches (
    id                       BIGSERIAL,
    transaction_date         DATE        NOT NULL,
    site                     TEXT        NOT NULL,
    pos_id                   BIGINT,
    processor_id             BIGINT,
    match_outcome            TEXT        NOT NULL,
    delta_minor              BIGINT,
    minute_offset            INTEGER,
    last4_pan_match          BOOLEAN,
    terminal_match           BOOLEAN,
    confidence               NUMERIC(4,3) NOT NULL,
    reasoning                TEXT,
    computed_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    realm                    TEXT        NOT NULL DEFAULT 'work'
                                          CHECK (realm IN ('owner','work','family','shared')),
    PRIMARY KEY (id, transaction_date)
) PARTITION BY RANGE (transaction_date);

CREATE INDEX IF NOT EXISTS idx_match_fraud_outcomes
    ON mart.transaction_matches (transaction_date DESC, match_outcome)
    WHERE match_outcome IN ('pos_no_card','card_no_pos','phantom_refund');

-- -----------------------------------------------------------------------------
-- mart.expected_settlements
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS mart.expected_settlements (
    id                       BIGSERIAL,
    settlement_batch_id      TEXT        NOT NULL,
    processor                TEXT        NOT NULL,
    batch_date               DATE        NOT NULL,
    expected_amount_minor    BIGINT      NOT NULL,
    expected_fee_minor       BIGINT      NOT NULL,
    expected_payout_date     DATE        NOT NULL,
    matched_bank_line_id     BIGINT,
    matched_amount_minor     BIGINT,
    matched_at               TIMESTAMPTZ,
    delta_minor              BIGINT,
    status                   TEXT        NOT NULL,
    realm                    TEXT        NOT NULL DEFAULT 'work'
                                          CHECK (realm IN ('owner','work','family','shared')),
    PRIMARY KEY (id, batch_date),
    UNIQUE (settlement_batch_id, processor, batch_date)
) PARTITION BY RANGE (batch_date);

-- -----------------------------------------------------------------------------
-- mart.cash_variance
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS mart.cash_variance (
    id                       BIGSERIAL,
    transaction_date         DATE        NOT NULL,
    site                     TEXT        NOT NULL,
    shift_start_utc          TIMESTAMPTZ NOT NULL,
    shift_end_utc            TIMESTAMPTZ NOT NULL,
    operator_id              TEXT        NOT NULL,
    operator_name            TEXT,
    cash_expected_minor      BIGINT      NOT NULL,
    cash_declared_minor      BIGINT      NOT NULL,
    variance_minor           BIGINT      NOT NULL,
    voids_count              INTEGER     NOT NULL DEFAULT 0,
    voids_value_minor        BIGINT      NOT NULL DEFAULT 0,
    refunds_count            INTEGER     NOT NULL DEFAULT 0,
    refunds_value_minor      BIGINT      NOT NULL DEFAULT 0,
    open_tabs_count          INTEGER     NOT NULL DEFAULT 0,
    late_night_share         NUMERIC(4,3),
    comp_ratio               NUMERIC(4,3),
    computed_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    realm                    TEXT        NOT NULL DEFAULT 'work'
                                          CHECK (realm IN ('owner','work','family','shared')),
    PRIMARY KEY (id, transaction_date)
) PARTITION BY RANGE (transaction_date);

CREATE INDEX IF NOT EXISTS idx_cash_variance_operator
    ON mart.cash_variance (operator_id, transaction_date DESC);

-- -----------------------------------------------------------------------------
-- mart.exceptions (non-partitioned — append-only, low volume)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS mart.exceptions (
    id                       BIGSERIAL PRIMARY KEY,
    raised_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    severity                 TEXT        NOT NULL CHECK (severity IN ('low','medium','high','critical')),
    kind                     TEXT        NOT NULL,
    source                   TEXT,
    site                     TEXT,
    operator_id              TEXT,
    transaction_date         DATE,
    related_ids              JSONB,
    summary                  TEXT        NOT NULL,
    detail                   JSONB,
    status                   TEXT        NOT NULL DEFAULT 'open'
                                  CHECK (status IN ('open','reviewing','resolved','suppressed')),
    resolved_by              TEXT,
    resolved_at              TIMESTAMPTZ,
    resolution_note          TEXT,
    realm                    TEXT        NOT NULL DEFAULT 'work'
                                          CHECK (realm IN ('owner','work','family','shared'))
);
CREATE INDEX IF NOT EXISTS idx_exceptions_open_severity
    ON mart.exceptions (severity, raised_at DESC) WHERE status = 'open';
CREATE INDEX IF NOT EXISTS idx_exceptions_kind
    ON mart.exceptions (kind, raised_at DESC);

-- -----------------------------------------------------------------------------
-- Current-month partitions for every partitioned table.
--
-- Idempotent: only creates a partition if its name doesn't already exist.
-- Subsequent month rollover is handled by the PARTITION-ROLLOVER-001 n8n
-- workflow (cron 25 04 25 * *) — extended in V73 to cover these tables.
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    cur_month_start DATE := DATE_TRUNC('month', CURRENT_DATE)::DATE;
    cur_month_end   DATE := (DATE_TRUNC('month', CURRENT_DATE) + INTERVAL '1 month')::DATE;
    cur_tag         TEXT := TO_CHAR(CURRENT_DATE, 'YYYY_MM');
    partitioned     TEXT[] := ARRAY[
        'raw.dojo_transactions',
        'raw.clover_transactions',
        'raw.touchoffice_orders',
        'raw.bank_lines',
        'raw.caterbook_reservations',
        'staging.payments',
        'staging.bank_lines',
        'mart.daily_totals',
        'mart.transaction_matches',
        'mart.expected_settlements',
        'mart.cash_variance'
    ];
    t TEXT;
    schema_name TEXT;
    table_name TEXT;
    part_name TEXT;
BEGIN
    FOREACH t IN ARRAY partitioned LOOP
        schema_name := split_part(t, '.', 1);
        table_name  := split_part(t, '.', 2);
        part_name   := table_name || '_' || cur_tag;

        IF NOT EXISTS (
            SELECT 1 FROM pg_class c
              JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = schema_name
               AND c.relname = part_name
        ) THEN
            EXECUTE format(
                'CREATE TABLE %I.%I PARTITION OF %s FOR VALUES FROM (%L) TO (%L)',
                schema_name, part_name, t, cur_month_start, cur_month_end
            );
            RAISE NOTICE 'V72 partition: created %.%', schema_name, part_name;
        END IF;
    END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- Verification
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    schema_count INT;
    raw_tables INT;
    staging_tables INT;
    mart_tables INT;
BEGIN
    SELECT COUNT(*) INTO schema_count FROM information_schema.schemata
     WHERE schema_name IN ('raw','staging','mart');
    SELECT COUNT(*) INTO raw_tables     FROM information_schema.tables
     WHERE table_schema = 'raw'     AND table_type IN ('BASE TABLE');
    SELECT COUNT(*) INTO staging_tables FROM information_schema.tables
     WHERE table_schema = 'staging' AND table_type IN ('BASE TABLE');
    SELECT COUNT(*) INTO mart_tables    FROM information_schema.tables
     WHERE table_schema = 'mart'    AND table_type IN ('BASE TABLE');

    IF schema_count <> 3 THEN
        RAISE EXCEPTION 'V72: expected 3 schemas (raw/staging/mart), found %', schema_count;
    END IF;
    -- Each partitioned table counts as 1 table plus 1 partition = at least 2 rows in info_schema for some PG versions.
    -- Use a softer floor: each schema should have at least its non-partition table count.
    IF raw_tables < 6 THEN  -- imports + 5 source tables (partitions count too on PG14+)
        RAISE EXCEPTION 'V72: raw tables = % (expected ≥6)', raw_tables;
    END IF;
    IF staging_tables < 2 THEN
        RAISE EXCEPTION 'V72: staging tables = % (expected ≥2)', staging_tables;
    END IF;
    IF mart_tables < 5 THEN
        RAISE EXCEPTION 'V72: mart tables = % (expected ≥5)', mart_tables;
    END IF;

    RAISE NOTICE 'V72 verification PASS: raw=% staging=% mart=% tables.',
        raw_tables, staging_tables, mart_tables;
END $$;

COMMIT;
