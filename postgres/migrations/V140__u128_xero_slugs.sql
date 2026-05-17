-- V140 — U128: dashboard slugs over Xero data
BEGIN;
SELECT set_config('app.current_entity','all',false);
SELECT home_ai.set_realm('owner');

INSERT INTO query_whitelist (slug, display_name, sql_template, description,
                              created_by, realm, entity_id, intent_examples,
                              approved_at, approved_by)
VALUES
  ('xero_vs_email_orphans',
   'U128 — orphan invoices (email seen, no Xero match)',
   'SELECT COUNT(*) AS orphan_count,
           COUNT(*) FILTER (WHERE needs_forward) AS overdue_to_forward,
           COUNT(*) FILTER (WHERE forwarded_to_dext_at IS NOT NULL) AS already_forwarded,
           ROUND(SUM(COALESCE(gross_amount, amount_seen, 0))::numeric, 2) AS gbp_exposure
      FROM v_xero_orphan_inbox
     WHERE invoice_date >= CURRENT_DATE - 100',
   'Invoice emails received but not in Xero (last 100d). Shows £ exposure + forward state.',
   'u128','owner',1, ARRAY['xero orphans','missing from xero','dext forward queue'],
   now(),'u128'),

  ('xero_orphans_top_vendors',
   'U128 — top orphan vendors by £',
   'SELECT vendor_name,
           COUNT(*)::int AS n,
           ROUND(SUM(COALESCE(gross_amount, amount_seen, 0))::numeric, 2) AS gbp,
           MIN(invoice_date) AS oldest,
           MAX(invoice_date) AS newest
      FROM v_xero_orphan_inbox
     WHERE invoice_date >= CURRENT_DATE - 100
     GROUP BY 1
     ORDER BY gbp DESC NULLS LAST
     LIMIT 15',
   'Vendors with the most £ in unmatched invoice emails',
   'u128','owner',1, ARRAY['top orphan vendors'],
   now(),'u128'),

  ('xero_bills_recent',
   'U128 — recent Xero bills with line counts',
   'SELECT contact_name, invoice_number, invoice_date, total, status, line_count
      FROM v_xero_bills
     WHERE invoice_date >= CURRENT_DATE - 30
     ORDER BY invoice_date DESC, total DESC NULLS LAST
     LIMIT 50',
   'Bills entered to Xero in the last 30 days',
   'u128','owner',1, ARRAY['xero bills','recent bills'],
   now(),'u128')

ON CONFLICT (slug) DO UPDATE SET
  sql_template = EXCLUDED.sql_template, approved_at = now(), approved_by = 'u128';

COMMIT;
