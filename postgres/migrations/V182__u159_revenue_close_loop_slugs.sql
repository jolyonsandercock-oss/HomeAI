-- =============================================================================
-- V182 — U159: revenue close-the-loop slugs
-- =============================================================================
-- Phase 6 surfaced the cost side (invoices → matched → categorised).
-- Phase 7 surfaces the revenue side: bookings → covers → cash → recognised.
-- This migration adds the slugs that power the new revenue tile + drill-down.
-- =============================================================================

BEGIN;

INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES
(
  'frontend_revenue_today',
  'Revenue today — by source',
  'U159: today gross revenue split across rooms, food+drink, card payments.',
  E'WITH today AS (SELECT CURRENT_DATE::date AS d)
    SELECT ''rooms''::text AS source,
           COALESCE(SUM(rate_per_night), 0)::numeric(12,2) AS gross_gbp,
           count(*)::int AS units
      FROM caterbook_room_nights WHERE night_date = (SELECT d FROM today)
    UNION ALL
    SELECT ''food_drink''::text,
           COALESCE(SUM(value), 0)::numeric(12,2),
           count(*)::int
      FROM touchoffice_department_sales WHERE report_date = (SELECT d FROM today)
    UNION ALL
    SELECT ''card_payments''::text,
           COALESCE(SUM(transaction_amount), 0)::numeric(12,2),
           count(*)::int
      FROM dojo_transactions
     WHERE transaction_date = (SELECT d FROM today)
       AND transaction_outcome = ''Authorised''
       AND transaction_type    = ''Sale''',
  '{}', 'shared', true, NOW(), 'u159', 'u159'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES
(
  'frontend_revenue_7d',
  'Revenue last 7 days — by source',
  'U159: rolling 7d gross revenue per day, faceted by source. Drives sparkline.',
  E'WITH days AS (
      SELECT generate_series(CURRENT_DATE - 6, CURRENT_DATE, ''1 day''::interval)::date AS d
    )
    SELECT d.d AS day,
           ''rooms''::text AS source,
           COALESCE(SUM(rate_per_night), 0)::numeric(12,2) AS gross_gbp
      FROM days d
      LEFT JOIN caterbook_room_nights cb ON cb.night_date = d.d
     GROUP BY d.d
    UNION ALL
    SELECT d.d, ''food_drink''::text,
           COALESCE(SUM(value), 0)::numeric(12,2)
      FROM days d
      LEFT JOIN touchoffice_department_sales tof ON tof.report_date = d.d
     GROUP BY d.d
    UNION ALL
    SELECT d.d, ''card_payments''::text,
           COALESCE(SUM(transaction_amount), 0)::numeric(12,2)
      FROM days d
      LEFT JOIN dojo_transactions dj
        ON dj.transaction_date = d.d
       AND dj.transaction_outcome = ''Authorised''
       AND dj.transaction_type = ''Sale''
     GROUP BY d.d
     ORDER BY day, source',
  '{}', 'shared', true, NOW(), 'u159', 'u159'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES
(
  'frontend_revenue_today_vs_last_week',
  'Revenue today vs same day last week',
  'U159: percentage delta of today gross vs same-DOW 7 days ago. Drives traffic-light tile.',
  E'WITH base AS (
      SELECT CURRENT_DATE AS today_d, CURRENT_DATE - 7 AS lastweek_d
    ),
    today_total AS (
      SELECT
        COALESCE((SELECT SUM(rate_per_night) FROM caterbook_room_nights WHERE night_date = (SELECT today_d FROM base)), 0) +
        COALESCE((SELECT SUM(value) FROM touchoffice_department_sales WHERE report_date = (SELECT today_d FROM base)), 0) AS gross
    ),
    last_total AS (
      SELECT
        COALESCE((SELECT SUM(rate_per_night) FROM caterbook_room_nights WHERE night_date = (SELECT lastweek_d FROM base)), 0) +
        COALESCE((SELECT SUM(value) FROM touchoffice_department_sales WHERE report_date = (SELECT lastweek_d FROM base)), 0) AS gross
    )
    SELECT
      (SELECT gross FROM today_total)::numeric(12,2) AS today_gross,
      (SELECT gross FROM last_total)::numeric(12,2)  AS lastweek_gross,
      CASE WHEN (SELECT gross FROM last_total) > 0 THEN
        ROUND(((SELECT gross FROM today_total) - (SELECT gross FROM last_total)) * 100.0 / (SELECT gross FROM last_total), 1)
        ELSE NULL
      END::numeric(6,1) AS pct_change',
  '{}', 'shared', true, NOW(), 'u159', 'u159'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES
(
  'frontend_revenue_breakdown_by_day',
  'Revenue breakdown for a specific day',
  'U159: detailed per-source revenue for a given date. Drives /work/revenue drill-down. Param: :for_date date.',
  E'WITH params AS (SELECT $1::date AS for_date)
    SELECT ''rooms''::text AS source,
           cb.room_type::text AS subcategory,
           COALESCE(SUM(cb.rate_per_night), 0)::numeric(12,2) AS gross_gbp,
           count(*)::int AS units
      FROM caterbook_room_nights cb, params
     WHERE cb.night_date = params.for_date
     GROUP BY cb.room_type
    UNION ALL
    SELECT ''food_drink''::text,
           tof.department::text,
           COALESCE(SUM(tof.value), 0)::numeric(12,2),
           count(*)::int
      FROM touchoffice_department_sales tof, params
     WHERE tof.report_date = params.for_date
     GROUP BY tof.department
    UNION ALL
    SELECT ''card_payments''::text,
           COALESCE(dj.location, ''unknown'')::text,
           COALESCE(SUM(dj.transaction_amount), 0)::numeric(12,2),
           count(*)::int
      FROM dojo_transactions dj, params
     WHERE dj.transaction_date = params.for_date
       AND dj.transaction_outcome = ''Authorised''
       AND dj.transaction_type    = ''Sale''
     GROUP BY dj.location
     ORDER BY source, gross_gbp DESC',
  '{"for_date": {"type": "string", "required": true}}',
  'shared', true, NOW(), 'u159', 'u159'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, param_schema = EXCLUDED.param_schema, approved_at = NOW();

COMMIT;
