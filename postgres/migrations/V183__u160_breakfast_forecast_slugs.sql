-- =============================================================================
-- V183 — U160: breakfast forecast + linkage slugs
-- =============================================================================
-- U160 hardens the breakfast pre-order loop. UI work is UX-postponed; this
-- migration delivers the backend slugs kitchen-staff + dashboard need.
-- =============================================================================

BEGIN;

INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES
(
  'breakfast_forecast_tomorrow',
  'Breakfast forecast — tomorrow',
  'U160: tomorrow per-item portion counts, grouped by service_time slot. Drives kitchen prep.',
  E'SELECT
      bo.dish,
      bo.dish_category,
      count(*) AS portions,
      array_agg(DISTINCT bo.service_time ORDER BY bo.service_time) AS service_slots,
      array_agg(bo.allergies) FILTER (WHERE bo.allergies IS NOT NULL AND bo.allergies <> '''') AS allergens
    FROM breakfast_orders bo
   WHERE bo.service_date = CURRENT_DATE + 1
   GROUP BY bo.dish, bo.dish_category
   ORDER BY portions DESC, bo.dish_category',
  '{}', 'shared', true, NOW(), 'u160', 'u160'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES
(
  'breakfast_coverage_next_7d',
  'Breakfast coverage — next 7 days',
  'U160: per-night arrivals count vs breakfast orders submitted. Identifies "no breakfast yet" gaps.',
  E'WITH days AS (
      SELECT generate_series(CURRENT_DATE, CURRENT_DATE + 7, ''1 day''::interval)::date AS d
    ),
    arrivals AS (
      SELECT
        ab.arrival_date AS night,
        count(*) AS guests_arriving
      FROM accommodation_bookings ab
      WHERE ab.arrival_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 7
      GROUP BY ab.arrival_date
    ),
    orders AS (
      SELECT
        bo.service_date AS night,
        count(*) AS orders_submitted
      FROM breakfast_orders bo
      WHERE bo.service_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 7
      GROUP BY bo.service_date
    )
    SELECT
      d.d AS service_date,
      COALESCE(a.guests_arriving, 0) AS arriving,
      COALESCE(o.orders_submitted, 0) AS orders,
      COALESCE(o.orders_submitted, 0)::numeric / NULLIF(a.guests_arriving, 0) AS coverage_ratio
    FROM days d
    LEFT JOIN arrivals a ON a.night = d.d
    LEFT JOIN orders   o ON o.night = d.d
    ORDER BY d.d',
  '{}', 'shared', true, NOW(), 'u160', 'u160'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES
(
  'breakfast_orders_by_token',
  'Breakfast orders — by token',
  'U160: all orders for a stay (email_token). Drives kitchen detail view.',
  E'SELECT id, guest_index, service_date, service_time, hot_drink, dish, dish_category, allergies, notes, submitted_at
      FROM breakfast_orders
     WHERE email_token = :email_token
     ORDER BY service_date, guest_index',
  '{"email_token": {"type": "string", "required": true}}',
  'shared', true, NOW(), 'u160', 'u160'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, param_schema = EXCLUDED.param_schema, approved_at = NOW();

COMMIT;
