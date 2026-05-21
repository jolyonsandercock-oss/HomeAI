-- =============================================================================
-- V185 — extend v_action_queue with email tasks + add menu-performance slugs
-- =============================================================================
-- Reported 2026-05-21: Gmail isn't populating on /tasks (action queue),
-- and Menu performance tile on /restaurant + /bar shows placeholder despite
-- touchoffice_plu_sales having 32k+ rows.
--
-- Two fixes:
--   1. v_action_queue extended with email_tasks UNION arm. The existing 5
--      arms (exception, invoice_review, bot_instruction, document_expiry,
--      vehicle_alert) all preserved.
--   2. New menu_performance_today + _7d + _by_site_today slugs.
-- =============================================================================

BEGIN;

CREATE OR REPLACE VIEW v_action_queue AS
  -- 1. Exceptions (existing)
  SELECT 'exception'::text AS source,
         e.id::text AS ref, e.severity, e.kind,
         COALESCE(e.summary, e.kind) AS title,
         COALESCE(e.transaction_date, e.raised_at::date) AS age_date,
         GREATEST(0, CURRENT_DATE - COALESCE(e.transaction_date, e.raised_at::date)) AS age_days,
         e.realm, e.detail AS extra
    FROM mart.exceptions e
   WHERE e.status = 'open'::text
     AND e.severity = ANY (ARRAY['critical'::text,'high'::text,'medium'::text])
  UNION ALL
  -- 2. Invoice review (existing)
  SELECT 'invoice_review'::text,
         v.id::text,
         CASE WHEN COALESCE(v.amount_seen, 0::numeric) >= 500::numeric THEN 'medium'::text ELSE 'low'::text END,
         'invoice_needs_review'::text,
         COALESCE(v.vendor_name, v.subject, 'Unknown vendor'::text),
         COALESCE(v.received_at::date, CURRENT_DATE),
         GREATEST(0, CURRENT_DATE - COALESCE(v.received_at::date, CURRENT_DATE)),
         COALESCE(v.realm, 'work'::text),
         jsonb_build_object('amount', v.amount_seen, 'vendor', v.vendor_name, 'subject', v.subject)
    FROM vendor_invoice_inbox v
   WHERE v.status = 'needs_review'::text
  UNION ALL
  -- 3. Bot instructions (existing)
  SELECT 'bot_instruction'::text,
         b.id::text, 'low'::text, 'instruction_pending'::text,
         COALESCE(LEFT(b.raw_subject, 120), 'Pending instruction'::text),
         COALESCE(b.received_at::date, CURRENT_DATE),
         GREATEST(0, CURRENT_DATE - COALESCE(b.received_at::date, CURRENT_DATE)),
         COALESCE(b.realm, 'work'::text),
         jsonb_build_object('lane', b.lane)
    FROM bot_instructions b
   WHERE b.status = 'pending'::text
  UNION ALL
  -- 4. Document expiry (existing)
  SELECT 'document_expiry'::text,
         d.id::text,
         CASE WHEN (d.expiry_date - CURRENT_DATE) < 14 THEN 'high'::text
              WHEN (d.expiry_date - CURRENT_DATE) < 30 THEN 'medium'::text
              ELSE 'low'::text END,
         'document_expiring'::text,
         COALESCE(d.title, d.category, 'Document'::text),
         d.expiry_date,
         GREATEST(0, d.expiry_date - CURRENT_DATE),
         COALESCE(d.realm, 'work'::text),
         jsonb_build_object('expiry', d.expiry_date, 'category', d.category)
    FROM v_documents_expiry_due d
   WHERE d.expiry_date IS NOT NULL
     AND (d.expiry_date - CURRENT_DATE) >= -7
     AND (d.expiry_date - CURRENT_DATE) <= 60
  UNION ALL
  -- 5. Vehicle alerts (existing)
  SELECT 'vehicle_alert'::text,
         (va.vehicle_id || ':' || va.kind),
         va.severity,
         'vehicle_' || va.kind,
         CASE WHEN va.last_signal_at IS NOT NULL THEN va.registration || ' ' || va.kind || ' due ' || va.due_date || ' (insurer on it)'
              WHEN va.days_to_due < 0 THEN va.registration || ' ' || va.kind || ' overdue (' || va.due_date || ')'
              ELSE va.registration || ' ' || va.kind || ' due ' || va.due_date END,
         va.due_date,
         CASE WHEN va.days_to_due < 0 THEN abs(va.days_to_due) ELSE 0 END,
         'family'::text,
         jsonb_build_object('vehicle_id', va.vehicle_id, 'registration', va.registration,
                            'make_model', va.make_model, 'kind', va.kind,
                            'due_date', va.due_date, 'days_to_due', va.days_to_due,
                            'last_signal_at', va.last_signal_at)
    FROM v_vehicle_alerts va
   WHERE va.severity IS NOT NULL
  UNION ALL
  -- 6. Email tasks (NEW — V185)
  SELECT 'email_task'::text,
         et.id::text,
         CASE WHEN et.severity >= 4 THEN 'high'::text
              WHEN et.severity >= 3 THEN 'medium'::text
              ELSE 'low'::text END,
         et.task_type,
         COALESCE(LEFT(et.subject, 120), et.task_type),
         COALESCE(et.due_by, et.detected_at::date),
         GREATEST(0, CURRENT_DATE - COALESCE(et.due_by, et.detected_at::date)),
         COALESCE(et.realm, 'work'::text),
         jsonb_build_object('account', et.account, 'task_type', et.task_type,
                            'severity_n', et.severity)
    FROM email_tasks et
   WHERE et.status = 'open'::text;

-- ── Menu-performance slugs ──

INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'menu_performance_today',
  'Menu performance — today (per-PLU sales)',
  'Today per-item sales from touchoffice_plu_sales. Drives Restaurant + Bar menu-perf tiles.',
  E'SELECT site, plu_number, descriptor,
           SUM(quantity)::numeric(10,2) AS qty,
           SUM(value)::numeric(12,2) AS gross_gbp,
           CASE WHEN SUM(quantity) > 0
                THEN (SUM(value) / SUM(quantity))::numeric(10,2)
                ELSE NULL END AS avg_price
      FROM touchoffice_plu_sales
     WHERE report_date = CURRENT_DATE
     GROUP BY site, plu_number, descriptor
     ORDER BY SUM(value) DESC NULLS LAST
     LIMIT 50',
  '{}', 'shared', true, NOW(), 'u162', 'u162'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'menu_performance_7d',
  'Menu performance — last 7 days (per-PLU sales)',
  'Rolling 7d per-item sales across all sites.',
  E'SELECT site, plu_number, descriptor,
           SUM(quantity)::numeric(12,2) AS qty,
           SUM(value)::numeric(14,2) AS gross_gbp,
           CASE WHEN SUM(quantity) > 0
                THEN (SUM(value) / SUM(quantity))::numeric(10,2)
                ELSE NULL END AS avg_price,
           count(DISTINCT report_date) AS days_with_sales
      FROM touchoffice_plu_sales
     WHERE report_date BETWEEN CURRENT_DATE - 6 AND CURRENT_DATE
     GROUP BY site, plu_number, descriptor
     ORDER BY SUM(value) DESC NULLS LAST
     LIMIT 100',
  '{}', 'shared', true, NOW(), 'u162', 'u162'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'menu_performance_by_site_today',
  'Menu performance — today by site',
  'Today top sellers grouped by site (pub vs cafe). Drives per-page tiles.',
  E'SELECT site, descriptor,
           SUM(quantity)::numeric(10,2) AS qty,
           SUM(value)::numeric(12,2) AS gross_gbp
      FROM touchoffice_plu_sales
     WHERE report_date = CURRENT_DATE
     GROUP BY site, descriptor
     ORDER BY site, SUM(value) DESC NULLS LAST
     LIMIT 30',
  '{}', 'shared', true, NOW(), 'u162', 'u162'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

COMMIT;
