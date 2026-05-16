-- =============================================================================
-- V113 — U84: exclude status='ignored' from /work/docs cost-centre split
-- =============================================================================
-- After V112 marked 886 noise-sender rows as 'ignored', the cost-centre
-- split tile still counted them as 'shared'. Update v_work_docs_kpis to
-- exclude ignored rows from pub/cafe/shared counts and from the 7d/30d
-- intake counters.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

CREATE OR REPLACE VIEW v_work_docs_kpis AS
SELECT
  -- Counts across all statuses
  (SELECT COUNT(*) FROM vendor_invoice_inbox)                                     AS total_invoices,
  (SELECT COUNT(*) FROM vendor_invoice_inbox WHERE status='new')                  AS new_count,
  (SELECT COUNT(*) FROM vendor_invoice_inbox WHERE status='extracted')            AS extracted_count,
  (SELECT COUNT(*) FROM vendor_invoice_inbox WHERE status='needs_review')         AS needs_review_count,
  (SELECT COUNT(*) FROM vendor_invoice_inbox WHERE status='ignored')              AS ignored_count,

  -- Cost-centre split — excludes 'ignored' so admin/notification noise
  -- doesn't dilute the supplier view.
  (SELECT COUNT(*) FROM vendor_invoice_inbox
     WHERE site='cafe' AND status <> 'ignored')                                   AS cafe_count,
  (SELECT COUNT(*) FROM vendor_invoice_inbox
     WHERE site='pub'  AND status <> 'ignored')                                   AS pub_count,
  (SELECT COUNT(*) FROM vendor_invoice_inbox
     WHERE (site IS NULL OR site='shared') AND status <> 'ignored')               AS shared_count,

  -- PDF coverage (all statuses)
  (SELECT COUNT(*) FROM vendor_invoice_inbox WHERE has_pdf=true)                  AS with_pdf_count,
  (SELECT COUNT(*) FROM vendor_invoice_inbox WHERE pdf_local_path IS NOT NULL)    AS with_local_pdf,

  -- Intake — excludes ignored
  (SELECT COUNT(*) FROM vendor_invoice_inbox
     WHERE received_at >= now() - INTERVAL '30 days' AND status <> 'ignored')     AS last_30d,
  (SELECT COUNT(*) FROM vendor_invoice_inbox
     WHERE received_at >= now() - INTERVAL '7 days'  AND status <> 'ignored')     AS last_7d;

COMMIT;
