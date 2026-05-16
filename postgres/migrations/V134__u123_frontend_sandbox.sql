-- =============================================================================
-- V134 — U123: Next.js frontend sandbox table + dashboard data slugs
-- =============================================================================
-- Sandbox comments table backs the EditModeContext drag+annotate flow in
-- the new Next.js frontend (HOMEAI-DASHBOARD-FRONTEND-SPRINT spec). One
-- row per (component_id, comment_text). Lightweight — anyone in 'owner'
-- realm can write; nothing else.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

CREATE TABLE IF NOT EXISTS sandbox_comments (
  id            BIGSERIAL PRIMARY KEY,
  component_id  TEXT NOT NULL,         -- e.g. "dashboard.revenue.gross"
  comment_text  TEXT NOT NULL,
  author        TEXT,
  page_path     TEXT,                  -- "/dashboard", "/sales" — for filtering by page
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at   TIMESTAMPTZ,
  realm         TEXT NOT NULL DEFAULT 'owner'
);
CREATE INDEX IF NOT EXISTS idx_sandbox_comments_component ON sandbox_comments (component_id);
CREATE INDEX IF NOT EXISTS idx_sandbox_comments_page ON sandbox_comments (page_path);
COMMENT ON TABLE sandbox_comments IS
'U123 V134. Free-text comments left by the operator on the front-end
sandbox layer. One row per (component_id, comment). The Next.js
SandboxWrapper reads/writes via /api/sandbox/comments.';

GRANT SELECT, INSERT, UPDATE ON sandbox_comments TO homeai_readonly;
GRANT USAGE ON SEQUENCE sandbox_comments_id_seq TO homeai_readonly;

CREATE TABLE IF NOT EXISTS sandbox_layout (
  id            BIGSERIAL PRIMARY KEY,
  page_path     TEXT NOT NULL,
  component_order JSONB NOT NULL,      -- ["dashboard.row1.kpi", "dashboard.row2.labour", …]
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  realm         TEXT NOT NULL DEFAULT 'owner',
  UNIQUE (page_path)
);
COMMENT ON TABLE sandbox_layout IS
'U123 V134. Sandbox-mode drag-and-drop ordering, per page. One row per
page_path. UPSERT on save. Reads cheap (single row per page).';

GRANT SELECT, INSERT, UPDATE ON sandbox_layout TO homeai_readonly;
GRANT USAGE ON SEQUENCE sandbox_layout_id_seq TO homeai_readonly;

-- Slugs the Next.js dashboard needs
INSERT INTO query_whitelist (slug, display_name, sql_template, description,
                              created_by, realm, entity_id, intent_examples,
                              approved_at, approved_by)
VALUES
  ('frontend_today_gross',
   'U123 — today gross revenue split',
   'SELECT site, SUM(value)::numeric(12,2) AS gross FROM touchoffice_department_sales WHERE report_date = CURRENT_DATE GROUP BY site',
   'Frontend Dashboard row 1: today gross by site',
   'u123','owner',1, ARRAY['frontend today gross'],
   now(),'u123'),

  ('frontend_seven_day_strip',
   'U123 — 7-day week strip',
   'WITH dates AS (SELECT generate_series(CURRENT_DATE - INTERVAL ''3 days'', CURRENT_DATE + INTERVAL ''3 days'', INTERVAL ''1 day'')::date AS d), sales AS (SELECT report_date, SUM(value)::numeric(12,2) AS gross FROM touchoffice_department_sales GROUP BY report_date), occ AS (SELECT checkin_date::date AS d, COUNT(DISTINCT id) FILTER (WHERE checkin_date <= dates.d AND checkout_date > dates.d) AS rooms_occupied FROM accommodation_bookings, dates WHERE status IN (''confirmed'',''deposit_paid'',''paid'',''active'') GROUP BY checkin_date::date), reservations AS (SELECT reservation_at::date AS d, COUNT(*) AS covers FROM restaurant_reservations WHERE status IN (''confirmed'',''enquiry'',''arrived'') GROUP BY reservation_at::date) SELECT d AS day, COALESCE(s.gross, 0) AS gross, COALESCE(o.rooms_occupied, 0) AS rooms, COALESCE(r.covers, 0) AS covers FROM dates LEFT JOIN sales s ON s.report_date = d LEFT JOIN occ o ON o.d = d LEFT JOIN reservations r ON r.d = d ORDER BY d',
   'Frontend Dashboard 7-day strip',
   'u123','owner',1, ARRAY['frontend 7d strip'],
   now(),'u123'),

  ('frontend_accommodation_today',
   'U123 — today accom in/out/stay',
   'SELECT (SELECT COUNT(*) FROM accommodation_bookings WHERE checkin_date = CURRENT_DATE AND status IN (''confirmed'',''deposit_paid'',''paid'',''active'')) AS arrivals, (SELECT COUNT(*) FROM accommodation_bookings WHERE checkout_date = CURRENT_DATE AND status IN (''confirmed'',''deposit_paid'',''paid'',''active'')) AS departures, (SELECT COUNT(*) FROM accommodation_bookings WHERE checkin_date < CURRENT_DATE AND checkout_date > CURRENT_DATE AND status IN (''confirmed'',''deposit_paid'',''paid'',''active'')) AS staying',
   'Today arrivals/staying/departures counts for Dashboard row 4',
   'u123','owner',1, ARRAY['frontend today accom'],
   now(),'u123'),

  ('frontend_rooms_today',
   'U123 — rooms today with status',
   'WITH ab AS (SELECT room, guest_name, checkin_date, checkout_date, gross_amount, payment_status FROM accommodation_bookings WHERE checkin_date <= CURRENT_DATE AND checkout_date >= CURRENT_DATE AND status IN (''confirmed'',''deposit_paid'',''paid'',''active'')) SELECT room, guest_name, checkout_date = CURRENT_DATE AS departing_today, checkin_date = CURRENT_DATE AS arriving_today, checkout_date - CURRENT_DATE AS nights_remaining, gross_amount, payment_status FROM ab ORDER BY room',
   'Frontend Rooms page primary data',
   'u123','owner',1, ARRAY['frontend rooms today'],
   now(),'u123'),

  ('frontend_restaurant_today',
   'U123 — restaurant run sheet today',
   'SELECT id, reservation_at, guest_name, party_size, booking_type, source_ref FROM restaurant_reservations WHERE reservation_at::date = CURRENT_DATE AND status IN (''confirmed'',''enquiry'',''arrived'') ORDER BY reservation_at',
   'Restaurant run sheet for today',
   'u123','owner',1, ARRAY['frontend restaurant today'],
   now(),'u123'),

  ('frontend_wage_pct_summary',
   'U123 — wage % 1D/7D/30D',
   'WITH params AS (SELECT 1 d UNION ALL SELECT 7 UNION ALL SELECT 30), labour AS (SELECT p.d, SUM(cost_with_oncost) c FROM params p, v_daily_labour_by_team l WHERE l.report_date BETWEEN CURRENT_DATE - p.d AND CURRENT_DATE - 1 GROUP BY p.d), sales AS (SELECT p.d, SUM(value) s FROM params p, touchoffice_department_sales s WHERE s.report_date BETWEEN CURRENT_DATE - p.d AND CURRENT_DATE - 1 GROUP BY p.d) SELECT p.d AS days, labour.c AS labour, sales.s AS sales, ROUND((labour.c / NULLIF(sales.s,0) * 100)::numeric, 1) AS pct FROM params p LEFT JOIN labour USING (d) LEFT JOIN sales USING (d) ORDER BY p.d',
   'Wage % rollup 1/7/30 day windows',
   'u123','owner',1, ARRAY['frontend wage pct'],
   now(),'u123'),

  ('frontend_invoices_recent',
   'U123 — recent invoices',
   'SELECT id, vendor_name, gross_amount, invoice_date, status FROM vendor_invoice_inbox WHERE invoice_date >= CURRENT_DATE - 30 AND status NOT IN (''duplicate'',''ignored'') ORDER BY invoice_date DESC LIMIT 100',
   'Recent invoices for Admin page',
   'u123','owner',1, ARRAY['frontend recent invoices'],
   now(),'u123'),

  ('frontend_action_queue',
   'U123 — open action queue',
   'SELECT * FROM v_action_queue WHERE status = ''open'' ORDER BY severity DESC NULLS LAST, age_days DESC LIMIT 200',
   'Open action queue items for Tasks/Back-end pages',
   'u123','owner',1, ARRAY['frontend action queue'],
   now(),'u123'),

  ('frontend_pipeline_health',
   'U123 — pipeline health',
   'SELECT pipeline_name, last_run_at, last_status, run_count_24h FROM v_pipeline_health ORDER BY last_run_at DESC NULLS LAST',
   'Pipeline last-run + status for Back-end page',
   'u123','owner',1, ARRAY['frontend pipeline health'],
   now(),'u123')

ON CONFLICT (slug) DO UPDATE SET
  sql_template=EXCLUDED.sql_template, approved_at=now(), approved_by='u123';

COMMIT;
