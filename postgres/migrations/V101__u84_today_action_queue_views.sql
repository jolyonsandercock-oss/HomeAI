-- =============================================================================
-- V101 — U84 Today screens + unified action queue
-- =============================================================================
-- Provides the SQL backing for the Phase 2 deliverables:
--   v_today_kpis_work     /work/today tile row
--   v_today_kpis_private  /private/today tile row
--   v_action_queue        unified action feed (exceptions + needs-review
--                         invoices + pending bot instructions + expiring docs)
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

-- ── v_action_queue ─────────────────────────────────────────────────────────
DROP VIEW IF EXISTS v_action_queue CASCADE;
CREATE VIEW v_action_queue AS

-- Open exceptions
SELECT
  'exception'::text                                                           AS source,
  e.id::text                                                                  AS ref,
  e.severity::text                                                            AS severity,
  e.kind::text                                                                AS kind,
  COALESCE(e.summary, e.kind)::text                                           AS title,
  COALESCE(e.transaction_date, e.raised_at::date)                             AS age_date,
  GREATEST(0, (CURRENT_DATE - COALESCE(e.transaction_date, e.raised_at::date))::int) AS age_days,
  e.realm::text                                                               AS realm,
  e.detail                                                                    AS extra
FROM mart.exceptions e
WHERE e.status = 'open'
  AND e.severity IN ('critical','high','medium')

UNION ALL

-- Invoices awaiting review
SELECT
  'invoice_review'::text                                                      AS source,
  v.id::text                                                                  AS ref,
  CASE
    WHEN COALESCE(v.amount_seen,0) >= 500 THEN 'medium'
    ELSE                                       'low'
  END::text                                                                   AS severity,
  'invoice_needs_review'::text                                                AS kind,
  COALESCE(v.vendor_name, v.subject, 'Unknown vendor')::text                  AS title,
  COALESCE(v.received_at::date, CURRENT_DATE)                                 AS age_date,
  GREATEST(0, (CURRENT_DATE - COALESCE(v.received_at::date, CURRENT_DATE))::int) AS age_days,
  COALESCE(v.realm, 'work')::text                                             AS realm,
  jsonb_build_object(
    'amount',  v.amount_seen,
    'vendor',  v.vendor_name,
    'subject', v.subject
  )                                                                           AS extra
FROM vendor_invoice_inbox v
WHERE v.status = 'needs_review'

UNION ALL

-- Pending bot instructions
SELECT
  'bot_instruction'::text                                                     AS source,
  b.id::text                                                                  AS ref,
  'low'::text                                                                 AS severity,
  'instruction_pending'::text                                                 AS kind,
  COALESCE(LEFT(b.raw_subject, 120), 'Pending instruction')::text             AS title,
  COALESCE(b.received_at::date, CURRENT_DATE)                                 AS age_date,
  GREATEST(0, (CURRENT_DATE - COALESCE(b.received_at::date, CURRENT_DATE))::int) AS age_days,
  COALESCE(b.realm, 'work')::text                                             AS realm,
  jsonb_build_object('lane', b.lane)                                          AS extra
FROM bot_instructions b
WHERE b.status = 'pending'

UNION ALL

-- Documents expiring inside 60 days
SELECT
  'document_expiry'::text                                                     AS source,
  d.id::text                                                                  AS ref,
  CASE
    WHEN (d.expiry_date - CURRENT_DATE) < 14 THEN 'high'
    WHEN (d.expiry_date - CURRENT_DATE) < 30 THEN 'medium'
    ELSE                                          'low'
  END::text                                                                   AS severity,
  'document_expiring'::text                                                   AS kind,
  COALESCE(d.title, d.category, 'Document')::text                             AS title,
  d.expiry_date                                                               AS age_date,
  GREATEST(0, (d.expiry_date - CURRENT_DATE)::int)                            AS age_days,
  COALESCE(d.realm, 'work')::text                                             AS realm,
  jsonb_build_object(
    'expiry',   d.expiry_date,
    'category', d.category
  )                                                                           AS extra
FROM v_documents_expiry_due d
WHERE d.expiry_date IS NOT NULL
  AND (d.expiry_date - CURRENT_DATE) BETWEEN -7 AND 60;

COMMENT ON VIEW v_action_queue IS
'U84 unified action feed (V101). Sourced from mart.exceptions, vendor_invoice_inbox,
bot_instructions, v_documents_expiry_due. RLS enforced via underlying tables.';

-- ── v_today_kpis_work ──────────────────────────────────────────────────────
DROP VIEW IF EXISTS v_today_kpis_work CASCADE;
CREATE VIEW v_today_kpis_work AS
SELECT
  (SELECT COALESCE(SUM(balance), 0)
     FROM v_account_balances_now
     WHERE realm = 'work')                                                    AS cash_on_hand,

  (SELECT COUNT(*) FROM v_action_queue
     WHERE realm IN ('work','shared')
       AND severity IN ('critical','high','medium'))                          AS open_actions_count,

  (SELECT COUNT(*) FROM v_action_queue
     WHERE realm IN ('work','shared')
       AND severity = 'critical')                                             AS critical_actions_count,

  (SELECT COUNT(*) FROM accommodation_bookings
     WHERE checkin_date = CURRENT_DATE
       AND status IN ('confirmed','deposit_paid','paid','active')
       AND realm = 'work')                                                    AS bookings_today,

  (SELECT COALESCE(SUM(gross_amount), 0) FROM accommodation_bookings
     WHERE checkin_date = CURRENT_DATE
       AND status IN ('confirmed','deposit_paid','paid','active')
       AND realm = 'work')                                                    AS bookings_today_revenue,

  (SELECT COUNT(*) FROM v_documents_expiry_due
     WHERE expiry_date IS NOT NULL
       AND (expiry_date - CURRENT_DATE) BETWEEN 0 AND 30
       AND COALESCE(realm, 'work') = 'work')                                  AS docs_expiring_30d,

  GREATEST(
    (SELECT MAX(ingested_at) FROM accommodation_bookings),
    (SELECT MAX(received_at) FROM vendor_invoice_inbox),
    (SELECT MAX(raised_at)   FROM mart.exceptions)
  )                                                                           AS last_data_at;

COMMENT ON VIEW v_today_kpis_work IS
'U84 /work/today KPI row (V101). One row, defensive COALESCEs.';

-- ── v_today_kpis_private ───────────────────────────────────────────────────
DROP VIEW IF EXISTS v_today_kpis_private CASCADE;
CREATE VIEW v_today_kpis_private AS
SELECT
  (SELECT COALESCE(SUM(balance), 0)
     FROM v_account_balances_now
     WHERE realm = 'family')                                                  AS cash_on_hand,

  (SELECT COUNT(*) FROM v_action_queue
     WHERE realm IN ('family','shared')
       AND severity IN ('critical','high','medium'))                          AS open_actions_count,

  (SELECT COUNT(*) FROM v_documents_expiry_due
     WHERE expiry_date IS NOT NULL
       AND (expiry_date - CURRENT_DATE) BETWEEN 0 AND 60
       AND COALESCE(realm, 'family') = 'family')                              AS docs_expiring_60d,

  (SELECT COUNT(*) FROM v_calendar_upcoming
     WHERE start_at::date BETWEEN CURRENT_DATE AND CURRENT_DATE + 7)          AS calendar_7d,

  (SELECT MAX(raised_at) FROM mart.exceptions)                                AS last_data_at;

COMMENT ON VIEW v_today_kpis_private IS
'U84 /private/today KPI row (V101). One row, defensive COALESCEs.';

-- ── Permissions ────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'homeai_pipeline') THEN
    EXECUTE 'GRANT SELECT ON v_action_queue, v_today_kpis_work, v_today_kpis_private TO homeai_pipeline';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'homeai_dashboard') THEN
    EXECUTE 'GRANT SELECT ON v_action_queue, v_today_kpis_work, v_today_kpis_private TO homeai_dashboard';
  END IF;
END$$;

-- ── Whitelist slugs (schema: slug, display_name, sql_template, …)
INSERT INTO query_whitelist (slug, display_name, sql_template, description,
                              created_by, realm, entity_id, intent_examples)
VALUES
  ('today_kpis_work',
   'U84 /work/today KPI row',
   'SELECT * FROM v_today_kpis_work',
   'U84 /work/today: cash, action counts, bookings today, doc expiries',
   'u84-phase2', 'owner', 1,
   ARRAY['what are the work KPIs today', 'work today']),
  ('today_kpis_private',
   'U84 /private/today KPI row',
   'SELECT * FROM v_today_kpis_private',
   'U84 /private/today: family cash, action counts, doc expiries, 7d calendar',
   'u84-phase2', 'owner', 1,
   ARRAY['what are the private KPIs today', 'private today']),
  ('action_queue',
   'U84 unified action queue',
   $$SELECT source, ref, severity, kind, title, age_days, realm, extra
       FROM v_action_queue
       ORDER BY
         CASE severity
           WHEN 'critical' THEN 0
           WHEN 'high'     THEN 1
           WHEN 'medium'   THEN 2
           WHEN 'low'      THEN 3
           ELSE                 4 END,
         age_days DESC
       LIMIT 100$$,
   'U84 action queue (top 100, severity then age sorted)',
   'u84-phase2', 'owner', 1,
   ARRAY['what actions do I need to take', 'show me the action queue'])
ON CONFLICT (slug) DO UPDATE
  SET sql_template = EXCLUDED.sql_template,
      description  = EXCLUDED.description,
      display_name = EXCLUDED.display_name,
      approved_at  = now(),
      approved_by  = 'u84-phase2';

COMMIT;
