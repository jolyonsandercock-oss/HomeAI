-- ============================================================
-- U32 — vendor categories: classify vendor_invoice_inbox by category
-- ============================================================
-- Adds a category column + a rules table mapping domain regex → category.
-- Categories chosen to match how a pub owner thinks about spend:
--   Food, Beverage, Utilities, Software, Maintenance, Laundry,
--   Bookings (booking-platform commissions), Other.
-- ============================================================

ALTER TABLE vendor_invoice_inbox
  ADD COLUMN IF NOT EXISTS vendor_category TEXT;

CREATE INDEX IF NOT EXISTS idx_vii_category ON vendor_invoice_inbox (vendor_category, received_at DESC);

CREATE TABLE IF NOT EXISTS vendor_category_rules (
  id              BIGSERIAL PRIMARY KEY,
  domain_pattern  TEXT NOT NULL,                -- POSIX regex against vendor_domain
  category        TEXT NOT NULL,
  vendor_display  TEXT,                          -- nicer name e.g. "Forest Produce"
  priority        INT NOT NULL DEFAULT 100,     -- lower = applied first
  notes           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (domain_pattern)
);

INSERT INTO vendor_category_rules (domain_pattern, category, vendor_display, priority) VALUES
  ('forestproduce',                    'Food',         'Forest Produce',         10),
  ('bidfreshfinance',                  'Food',         'Bidfresh',               10),
  ('westcountry',                      'Beverage',     'West Country',           10),
  ('staustellbrewery|staustell',       'Beverage',     'St Austell Brewery',     10),
  ('wolflaundry',                      'Laundry',      'Wolf Laundry',           10),
  ('theaccessgroup',                   'Software',     'The Access Group',       10),
  ('post\.xero\.com|xero\.com',        'Software',     'Xero',                   10),
  ('google\.com|workspace\.google',    'Software',     'Google Workspace',       10),
  ('designmynight',                    'Software',     'Design My Night',        10),
  ('encounterwalkingholidays',         'Bookings',     'Encounter Walking',      10),
  ('booking\.com|guest\.booking',      'Bookings',     'Booking.com',            10),
  ('partners\.collinsbookings',        'Bookings',     'Collins Bookings',       10),
  ('caterbook',                        'Bookings',     'Caterbook',              10),
  ('trip\.com',                        'Bookings',     'Trip.com',               10),
  ('bartlett',                         'Maintenance',  'Bartlett',               10),
  ('podfather',                        'Maintenance',  'Podfather',              10),
  ('cpnitro',                          'Beverage',     'CP Nitro',               10),
  ('partridge-ventilation',            'Maintenance',  'Partridge Ventilation',  10),
  ('tfs-sw',                           'Software',     'TFS',                    10),
  ('quatra',                           'Maintenance',  'Quatra',                 10),
  ('trelawneyfs',                      'Maintenance',  'Trelawney FS',           10),
  ('stephanus',                        'Software',     'Stephanus',              10),
  ('malthousetintagel',                'Other',        'Internal',              100)
ON CONFLICT (domain_pattern) DO NOTHING;

-- Backfill existing rows
UPDATE vendor_invoice_inbox v
   SET vendor_category = r.category,
       vendor_name     = COALESCE(v.vendor_name, r.vendor_display)
  FROM (
    SELECT DISTINCT ON (v2.id)
      v2.id, r2.category, r2.vendor_display
    FROM vendor_invoice_inbox v2
    JOIN vendor_category_rules r2 ON v2.vendor_domain ~* r2.domain_pattern
    ORDER BY v2.id, r2.priority
  ) r
 WHERE v.id = r.id;

-- Set any still-uncategorised to 'Other'
UPDATE vendor_invoice_inbox SET vendor_category = 'Other' WHERE vendor_category IS NULL;

GRANT SELECT, INSERT, UPDATE, DELETE ON vendor_category_rules TO homeai_pipeline;
GRANT USAGE, SELECT ON vendor_category_rules_id_seq TO homeai_pipeline;
GRANT SELECT ON vendor_category_rules TO homeai_readonly;


-- ── Spend rollup view ─────────────────────────────────────
CREATE OR REPLACE VIEW v_daily_spend AS
SELECT
  received_at::date AS spend_date,
  vendor_category,
  COUNT(*)          AS invoice_count,
  SUM(amount_seen)  AS amount_seen,
  ARRAY_AGG(DISTINCT vendor_domain) AS vendors
FROM vendor_invoice_inbox
WHERE status != 'ignored'
GROUP BY 1, 2;

CREATE OR REPLACE VIEW v_weekly_spend AS
SELECT
  date_trunc('week', received_at)::date AS week_start,
  vendor_category,
  COUNT(*)          AS invoice_count,
  SUM(amount_seen)  AS amount_seen
FROM vendor_invoice_inbox
WHERE status != 'ignored'
GROUP BY 1, 2;

GRANT SELECT ON v_daily_spend, v_weekly_spend TO homeai_pipeline, homeai_readonly;
