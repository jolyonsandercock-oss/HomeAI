-- =============================================================================
-- V104 — U84 Phase 3: /work/docs KPI view + slug
-- =============================================================================
-- Powers the /work/docs page. Tile counts: total invoices, status breakdown,
-- cost-centre split (pub/cafe/shared per V103 site classifier), PDF coverage,
-- 7d/30d intake.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

DROP VIEW IF EXISTS v_work_docs_kpis;
CREATE VIEW v_work_docs_kpis AS
SELECT
  (SELECT COUNT(*) FROM vendor_invoice_inbox)                                     AS total_invoices,
  (SELECT COUNT(*) FROM vendor_invoice_inbox WHERE status='new')                  AS new_count,
  (SELECT COUNT(*) FROM vendor_invoice_inbox WHERE status='extracted')            AS extracted_count,
  (SELECT COUNT(*) FROM vendor_invoice_inbox WHERE status='needs_review')         AS needs_review_count,
  (SELECT COUNT(*) FROM vendor_invoice_inbox WHERE status='ignored')              AS ignored_count,
  (SELECT COUNT(*) FROM vendor_invoice_inbox WHERE site='cafe')                   AS cafe_count,
  (SELECT COUNT(*) FROM vendor_invoice_inbox WHERE site='pub')                    AS pub_count,
  (SELECT COUNT(*) FROM vendor_invoice_inbox WHERE site IS NULL OR site='shared') AS shared_count,
  (SELECT COUNT(*) FROM vendor_invoice_inbox WHERE has_pdf=true)                  AS with_pdf_count,
  (SELECT COUNT(*) FROM vendor_invoice_inbox WHERE pdf_local_path IS NOT NULL)    AS with_local_pdf,
  (SELECT COUNT(*) FROM vendor_invoice_inbox
     WHERE received_at >= now() - INTERVAL '30 days')                             AS last_30d,
  (SELECT COUNT(*) FROM vendor_invoice_inbox
     WHERE received_at >= now() - INTERVAL '7 days')                              AS last_7d;

COMMENT ON VIEW v_work_docs_kpis IS
'U84 /work/docs KPI row (V104). Status, site, PDF coverage, 7d/30d intake.';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'homeai_pipeline') THEN
    EXECUTE 'GRANT SELECT ON v_work_docs_kpis TO homeai_pipeline';
  END IF;
END$$;

INSERT INTO query_whitelist (slug, display_name, sql_template, description,
                              created_by, realm, entity_id, intent_examples,
                              approved_at, approved_by)
VALUES (
  'work_docs_kpis',
  'U84 /work/docs — docs + invoices KPI row',
  'SELECT * FROM v_work_docs_kpis',
  'Counts: total, new, extracted, needs_review, ignored; site split; PDF coverage; 7d/30d intake',
  'u84-phase3', 'owner', 1,
  ARRAY['docs overview', 'invoices stats'],
  now(), 'u84-phase3'
) ON CONFLICT (slug) DO UPDATE
  SET sql_template = EXCLUDED.sql_template,
      description  = EXCLUDED.description,
      display_name = EXCLUDED.display_name,
      approved_at  = now(),
      approved_by  = 'u84-phase3';

COMMIT;
