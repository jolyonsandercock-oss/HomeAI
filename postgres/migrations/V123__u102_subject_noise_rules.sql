-- =============================================================================
-- V123 — U102: subject-pattern noise rules (Amazon shipment/payment noise)
-- =============================================================================
-- Some senders we keep (Amazon — real invoices) but with noisy subjects
-- mixed in (Payment Declined, Shipped, Delivered). V112's domain-level
-- ignore doesn't suit — we want only the noisy SUBJECTS dropped.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

CREATE TABLE IF NOT EXISTS invoice_noise_subjects (
  id              BIGSERIAL PRIMARY KEY,
  vendor_domain   TEXT,             -- NULL = any vendor
  subject_pattern TEXT NOT NULL,    -- ILIKE pattern
  reason          TEXT NOT NULL,
  active          BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by      TEXT NOT NULL DEFAULT 'system',
  UNIQUE (vendor_domain, subject_pattern)
);

COMMENT ON TABLE invoice_noise_subjects IS
'U102 V123. Per-(vendor, subject) noise rules. Used when a vendor sends
real invoices alongside notifications (Amazon, etc.). Matches subject
via ILIKE; vendor_domain NULL means apply to any vendor.';

INSERT INTO invoice_noise_subjects (vendor_domain, subject_pattern, reason) VALUES
  ('amazon.co.uk', 'Payment Declined%',                  'Amazon — payment failure notification'),
  ('amazon.co.uk', '%shipped%',                          'Amazon — shipment notification'),
  ('amazon.co.uk', '%shipment%',                         'Amazon — shipment notification'),
  ('amazon.co.uk', '%delivered%',                        'Amazon — delivery confirmation'),
  ('amazon.co.uk', '%password%',                         'Amazon — auth noise'),
  ('amazon.co.uk', '%sign-in%',                          'Amazon — auth noise'),
  ('amazon.co.uk', 'Return%',                            'Amazon — return notification (refund tracked separately)')
ON CONFLICT (vendor_domain, subject_pattern) DO NOTHING;

-- Apply the rules to existing rows
WITH bumped AS (
  UPDATE vendor_invoice_inbox v
     SET status = 'ignored'
   WHERE v.status IN ('new','needs_review')
     AND EXISTS (
       SELECT 1 FROM invoice_noise_subjects r
        WHERE r.active
          AND (r.vendor_domain IS NULL OR r.vendor_domain = v.vendor_domain)
          AND v.subject ILIKE r.subject_pattern
     )
   RETURNING v.id
)
SELECT 'V123 ignored ' || COUNT(*) || ' subject-noise rows' AS result FROM bumped;

COMMIT;
