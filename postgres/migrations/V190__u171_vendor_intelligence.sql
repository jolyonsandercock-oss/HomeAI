-- =============================================================================
-- V190 — U171: vendor intelligence slugs
-- =============================================================================
-- Build on existing xero_bills + xero_bill_lines + vendor_invoice_inbox
-- to surface vendor patterns:
--   - top vendors by spend (last 30/90 days)
--   - vendor price-creep detection (same item, unit price trending up)
--   - vendor reorder cadence (how often do we buy)
--   - vendor invoice count + drift vs prior period
-- =============================================================================

BEGIN;

INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'vendor_spend_90d',
  'Vendor spend — last 90 days',
  'U171: top vendors by spend over 90d with invoice count + average bill size.',
  E'SELECT
      contact_name AS vendor,
      count(*) AS invoices,
      SUM(total)::numeric(12,2) AS total_gbp,
      AVG(total)::numeric(10,2) AS avg_bill,
      MIN(invoice_date) AS earliest,
      MAX(invoice_date) AS latest,
      EXTRACT(DAY FROM (MAX(invoice_date) - MIN(invoice_date)))::int AS span_days,
      CASE WHEN count(*) > 1
        THEN ROUND(EXTRACT(DAY FROM (MAX(invoice_date) - MIN(invoice_date))) * 1.0 / (count(*) - 1), 1)
      END AS avg_days_between
    FROM xero_bills
    WHERE invoice_date > CURRENT_DATE - 90
    GROUP BY contact_name
    HAVING SUM(total) > 0
    ORDER BY SUM(total) DESC NULLS LAST
    LIMIT 30',
  '{}', 'shared', true, NOW(), 'u171', 'u171'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'vendor_spend_trend_90v90',
  'Vendor spend trend — last 90d vs prior 90d',
  'U171: per-vendor delta between current 90d and prior 90d. Flags creep or shrink >20%.',
  E'WITH recent AS (
      SELECT contact_name, SUM(total)::numeric(12,2) AS spend, count(*) AS invoices
        FROM xero_bills
       WHERE invoice_date BETWEEN CURRENT_DATE - 90 AND CURRENT_DATE
       GROUP BY contact_name
    ),
    prior AS (
      SELECT contact_name, SUM(total)::numeric(12,2) AS spend, count(*) AS invoices
        FROM xero_bills
       WHERE invoice_date BETWEEN CURRENT_DATE - 180 AND CURRENT_DATE - 91
       GROUP BY contact_name
    )
    SELECT
      COALESCE(r.contact_name, p.contact_name) AS vendor,
      COALESCE(r.spend, 0) AS recent_90d,
      COALESCE(p.spend, 0) AS prior_90d,
      COALESCE(r.spend, 0) - COALESCE(p.spend, 0) AS delta,
      CASE WHEN COALESCE(p.spend, 0) > 0 THEN
        ROUND((COALESCE(r.spend, 0) - p.spend) * 100.0 / p.spend, 1)
      END AS pct_change
    FROM recent r FULL OUTER JOIN prior p USING (contact_name)
    WHERE COALESCE(r.spend, 0) + COALESCE(p.spend, 0) > 50
    ORDER BY ABS(COALESCE(r.spend, 0) - COALESCE(p.spend, 0)) DESC
    LIMIT 30',
  '{}', 'shared', true, NOW(), 'u171', 'u171'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'vendor_price_creep_180d',
  'Vendor item price creep — last 180 days',
  'U171: per (vendor, item description), unit price trend. Flags >10% movement on items billed 3+ times.',
  E'WITH item_lines AS (
      SELECT xb.contact_name AS vendor,
             xbl.description AS item,
             xb.invoice_date AS bill_date,
             xbl.unit_amount,
             xbl.quantity
        FROM xero_bills xb
        JOIN xero_bill_lines xbl ON xbl.bill_id = xb.id
       WHERE xb.invoice_date > CURRENT_DATE - 180
         AND xbl.unit_amount IS NOT NULL
         AND xbl.quantity IS NOT NULL
         AND xbl.unit_amount > 0
    ),
    earliest_latest AS (
      SELECT
        vendor, item,
        count(*) AS n_billed,
        MIN(bill_date) AS first_seen,
        MAX(bill_date) AS last_seen,
        (array_agg(unit_amount ORDER BY bill_date ASC))[1] AS first_price,
        (array_agg(unit_amount ORDER BY bill_date DESC))[1] AS last_price,
        AVG(unit_amount)::numeric(10,2) AS avg_price
      FROM item_lines
      GROUP BY vendor, item
      HAVING count(*) >= 3
    )
    SELECT
      vendor, item, n_billed, first_seen, last_seen,
      first_price, last_price, avg_price,
      ROUND((last_price - first_price) * 100.0 / NULLIF(first_price, 0), 1) AS pct_change,
      CASE
        WHEN ABS((last_price - first_price) * 100.0 / NULLIF(first_price, 0)) > 20 THEN ''⚠ big move''
        WHEN ABS((last_price - first_price) * 100.0 / NULLIF(first_price, 0)) > 10 THEN ''moderate''
        ELSE ''stable''
      END AS verdict
    FROM earliest_latest
    WHERE ABS((last_price - first_price) * 100.0 / NULLIF(first_price, 0)) > 5
    ORDER BY ABS((last_price - first_price) * 100.0 / NULLIF(first_price, 0)) DESC
    LIMIT 30',
  '{}', 'shared', true, NOW(), 'u171', 'u171'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'vendor_due_for_reorder',
  'Vendors overdue for reorder',
  'U171: vendors with consistent past cadence whose latest invoice is >1.5x their avg gap.',
  E'WITH cadence AS (
      SELECT contact_name AS vendor,
             MAX(invoice_date) AS last_invoice,
             EXTRACT(DAY FROM (MAX(invoice_date) - MIN(invoice_date))) / NULLIF(count(*) - 1, 0) AS avg_days,
             count(*) AS n_invoices
        FROM xero_bills
       WHERE invoice_date > CURRENT_DATE - 180
       GROUP BY contact_name
       HAVING count(*) >= 5
    )
    SELECT
      vendor, last_invoice,
      ROUND(avg_days::numeric, 1) AS avg_gap_days,
      (CURRENT_DATE - last_invoice) AS days_since_last,
      n_invoices,
      ROUND((CURRENT_DATE - last_invoice)::numeric / avg_days::numeric, 2) AS overdue_ratio
    FROM cadence
    WHERE (CURRENT_DATE - last_invoice) > avg_days * 1.5
      AND avg_days >= 3
    ORDER BY overdue_ratio DESC
    LIMIT 20',
  '{}', 'shared', true, NOW(), 'u171', 'u171'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

COMMIT;
