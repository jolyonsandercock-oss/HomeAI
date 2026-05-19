-- =============================================================================
-- V156 — U135 T6: cashup_inputs + safe_movements tables
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS cashup_inputs (
    id              BIGSERIAL PRIMARY KEY,
    site            TEXT NOT NULL CHECK (site IN ('malthouse','sandwich')),
    cashup_date     DATE NOT NULL,
    till_id         TEXT NOT NULL,                  -- 'till_bar', 'till_restaurant', 'till_cafe' etc.
    z_read_pence    INTEGER,                        -- TouchOffice Z-read total
    cash_taken_pence INTEGER,                       -- manual entry: cash counted out of till
    card_pence      INTEGER,                        -- from Dojo
    caterpay_pence  INTEGER,                        -- accommodation deposits via Caterbook
    collins_deposit_pence INTEGER,                  -- restaurant deposits via Collins
    manual_notes    TEXT,
    entered_by      TEXT,
    entered_at      TIMESTAMPTZ DEFAULT now(),
    realm           TEXT NOT NULL DEFAULT 'work',
    UNIQUE (site, cashup_date, till_id)
);
CREATE INDEX IF NOT EXISTS idx_cashup_inputs_date ON cashup_inputs (cashup_date DESC);

CREATE TABLE IF NOT EXISTS safe_movements (
    id              BIGSERIAL PRIMARY KEY,
    movement_date   DATE NOT NULL,
    site            TEXT NOT NULL CHECK (site IN ('malthouse','sandwich')),
    direction       TEXT NOT NULL CHECK (direction IN ('to_safe','from_safe')),
    amount_pence    INTEGER NOT NULL CHECK (amount_pence > 0),
    notes           TEXT,
    entered_by      TEXT,
    entered_at      TIMESTAMPTZ DEFAULT now(),
    realm           TEXT NOT NULL DEFAULT 'work'
);
CREATE INDEX IF NOT EXISTS idx_safe_movements_date_site
    ON safe_movements (movement_date DESC, site);

-- Tills-per-site is configurable. Default: malthouse has 2 (bar + restaurant);
-- sandwich has 1 (cafe). Adjust via UPDATE on static_context.
INSERT INTO static_context (key, value, realm)
VALUES ('cashup.tills', '{"malthouse": ["till_bar", "till_restaurant"], "sandwich": ["till_cafe"]}'::jsonb, 'work')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
