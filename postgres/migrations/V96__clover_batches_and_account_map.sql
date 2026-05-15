-- V96: Clover merchant batches + account-to-property registry.
--
-- Why now: scanned Clover statements give daily settlement batches (not
-- transaction-level rows) for accommodation card receipts at the Malthouse.
-- We mirror dojo_transactions' realm/entity isolation so the batches feed
-- the same reconciliation views.
--
-- Also seeds account_property_map: a lookup that ties future bills'
-- account numbers to specific properties/entities, so utility bills auto-
-- route on subsequent scans.

BEGIN;

-- ===========================================================================
-- 1. clover_batches — one row per daily settlement batch.
-- ===========================================================================
CREATE TABLE clover_batches (
    id                     BIGSERIAL PRIMARY KEY,
    entity_id              INTEGER NOT NULL REFERENCES entities(id),
    realm                  TEXT NOT NULL DEFAULT 'work',
    mid                    TEXT NOT NULL,
    site                   TEXT NOT NULL,
    batch_date             DATE NOT NULL,
    batch_number           TEXT NOT NULL,
    visa_amount            NUMERIC(12,2) NOT NULL DEFAULT 0,
    visa_debit_amount      NUMERIC(12,2) NOT NULL DEFAULT 0,
    mc_consumer_amount     NUMERIC(12,2) NOT NULL DEFAULT 0,
    mc_purchasing_amount   NUMERIC(12,2) NOT NULL DEFAULT 0,
    mc_debit_amount        NUMERIC(12,2) NOT NULL DEFAULT 0,
    gross_amount           NUMERIC(12,2) NOT NULL,
    statement_period_start DATE,
    statement_period_end   DATE,
    source_document_id     BIGINT REFERENCES documents(id),
    idempotency_key        TEXT NOT NULL,
    imported_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT clover_batches_realm_check
        CHECK (realm = ANY (ARRAY['owner','work','family','shared'])),
    CONSTRAINT clover_batches_unique_batch
        UNIQUE (mid, batch_date, batch_number)
);

CREATE INDEX idx_clover_batches_entity ON clover_batches (entity_id);
CREATE INDEX idx_clover_batches_date   ON clover_batches (batch_date DESC);
CREATE INDEX idx_clover_batches_site   ON clover_batches (site, batch_date DESC);

ALTER TABLE clover_batches ENABLE ROW LEVEL SECURITY;

CREATE POLICY entity_isolation ON clover_batches
    USING (CASE
        WHEN current_setting('app.current_entity', true) = 'all' THEN true
        WHEN current_setting('app.current_entity', true) ~ '^\d+$'
            THEN entity_id = current_setting('app.current_entity', true)::integer
        ELSE false
    END)
    WITH CHECK (CASE
        WHEN current_setting('app.current_entity', true) = 'all' THEN true
        WHEN current_setting('app.current_entity', true) ~ '^\d+$'
            THEN entity_id = current_setting('app.current_entity', true)::integer
        ELSE false
    END);

CREATE POLICY realm_isolation ON clover_batches AS RESTRICTIVE
    USING (CASE
        WHEN current_setting('app.current_realm', true) = 'owner' THEN true
        WHEN current_setting('app.current_realm', true) = 'work'
            THEN realm = ANY (ARRAY['work','shared'])
        WHEN current_setting('app.current_realm', true) = 'family'
            THEN realm = ANY (ARRAY['family','shared'])
        WHEN current_setting('app.current_realm', true) IS NULL
          OR current_setting('app.current_realm', true) = '' THEN true
        ELSE false
    END);

-- ===========================================================================
-- 2. v_clover_daily — daily rollup, shape mirrors v_dojo_daily so it can
--    drop into reconciliation views without bespoke joins.
-- ===========================================================================
CREATE OR REPLACE VIEW v_clover_daily AS
SELECT
    batch_date AS date,
    site,
    entity_id,
    realm,
    COUNT(*)::int AS batch_count,
    SUM(visa_amount + visa_debit_amount + mc_consumer_amount +
        mc_purchasing_amount + mc_debit_amount)::numeric(12,2) AS gross_sales,
    SUM(visa_amount + visa_debit_amount)::numeric(12,2) AS visa_total,
    SUM(mc_consumer_amount + mc_purchasing_amount + mc_debit_amount)::numeric(12,2)
        AS mastercard_total
FROM clover_batches
GROUP BY batch_date, site, entity_id, realm;

-- ===========================================================================
-- 3. account_property_map — registry of vendor account-numbers → property/
--    entity. The utility-bill ingest checks this on every new scan; an
--    unknown account-number opens a bot_instructions row so Jo can map it.
-- ===========================================================================
CREATE TABLE account_property_map (
    id                 BIGSERIAL PRIMARY KEY,
    vendor_domain      TEXT,                       -- e.g. 'source4b.co.uk'
    vendor_name        TEXT,                       -- 'South West Water'
    account_number     TEXT NOT NULL,              -- normalised: digits only
    account_display    TEXT,                       -- original formatting
    entity_id          INTEGER NOT NULL REFERENCES entities(id),
    property_id        INTEGER REFERENCES properties(id),
    site               TEXT,                       -- 'castle-rd', 'pub', etc.
    category_canonical TEXT,                       -- 'utility_water', etc.
    realm              TEXT NOT NULL DEFAULT 'work',
    notes              TEXT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by         TEXT,
    CONSTRAINT account_property_map_realm_check
        CHECK (realm = ANY (ARRAY['owner','work','family','shared'])),
    CONSTRAINT account_property_map_unique
        UNIQUE (vendor_domain, account_number)
);

CREATE INDEX idx_apm_lookup ON account_property_map (account_number);
CREATE INDEX idx_apm_entity ON account_property_map (entity_id);

ALTER TABLE account_property_map ENABLE ROW LEVEL SECURITY;

-- Registry is read across entities for routing; allow 'all' context to see
-- everything, otherwise scope to current entity.
CREATE POLICY entity_isolation ON account_property_map
    USING (CASE
        WHEN current_setting('app.current_entity', true) = 'all' THEN true
        WHEN current_setting('app.current_entity', true) ~ '^\d+$'
            THEN entity_id = current_setting('app.current_entity', true)::integer
        ELSE false
    END)
    WITH CHECK (CASE
        WHEN current_setting('app.current_entity', true) = 'all' THEN true
        WHEN current_setting('app.current_entity', true) ~ '^\d+$'
            THEN entity_id = current_setting('app.current_entity', true)::integer
        ELSE false
    END);

COMMIT;
