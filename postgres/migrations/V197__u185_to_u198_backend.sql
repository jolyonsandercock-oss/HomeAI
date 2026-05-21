-- =============================================================================
-- V197 — U185 + U186 + U189 + U190 + U191 + U192 + U196 + U197 + U198 backend
-- =============================================================================
-- Backend plumbing for the UX viz sprints + the operational-oracle SPEC items.
-- All slug additions + supporting columns. Frontend wires next.
-- =============================================================================

BEGIN;

-- ── U191: contextual empty states ─────────────────────────────────────
-- Add notes column already exists in query_whitelist; we'll use it.
-- Add a dedicated empty_state_md column for rich markdown when 0 rows.
ALTER TABLE query_whitelist
  ADD COLUMN IF NOT EXISTS empty_state_md TEXT;

-- Seed contextual empty states for known "correctly empty" slugs
UPDATE query_whitelist SET empty_state_md =
  'No reservations for tonight. Last Collins poll: see data_source_freshness.'
WHERE slug = 'frontend_restaurant_today';
UPDATE query_whitelist SET empty_state_md =
  'Trail integration awaiting OIDC pair. Run u156-trail-pair.sh on console.'
WHERE slug = 'trail_reports_today';
UPDATE query_whitelist SET empty_state_md =
  'No reviews scraped yet. Scrape runs daily 06:30; reviews now sourced via notification emails (u163).'
WHERE slug IN ('reviews_recent', 'reviews_average_30d');
UPDATE query_whitelist SET empty_state_md =
  'No actions outstanding. Refresh in 60s for new items.'
WHERE slug = 'frontend_action_queue';
UPDATE query_whitelist SET empty_state_md =
  'No breakfast orders yet. Guests usually order by 9pm prior night.'
WHERE slug = 'breakfast_forecast_tomorrow';

-- ── U185: spark-line companion slugs (7d compact arrays) ─────────────
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'revenue_spark_7d',
  'Revenue sparkline 7d (compact array)',
  'U185: 7-element float array for sparkline rendering. Today excluded so spark is stable.',
  E'SELECT
      array_agg(coalesce(daily, 0) ORDER BY d) AS values
    FROM (
      SELECT d.d,
        (COALESCE((SELECT SUM(value) FROM touchoffice_department_sales WHERE report_date = d.d), 0)
       + COALESCE((SELECT SUM(rate_per_night) FROM caterbook_room_nights WHERE night_date = d.d), 0))::numeric(12,2) AS daily
      FROM generate_series(CURRENT_DATE - 7, CURRENT_DATE - 1, ''1 day''::interval) d(d)
    ) sub',
  '{}', 'shared', true, NOW(), 'u185', 'u185'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'labour_pct_spark_7d',
  'Labour % sparkline 7d',
  'U185: 7-day labour % trend for the sparkline on the labour tile.',
  E'WITH days AS (
      SELECT generate_series(CURRENT_DATE - 7, CURRENT_DATE - 1, ''1 day''::interval)::date AS d
    )
    SELECT array_agg(
      CASE WHEN sales > 0 THEN ROUND(100.0 * labour / sales, 1) ELSE NULL END
      ORDER BY d
    ) AS values
    FROM (
      SELECT d.d,
        COALESCE((SELECT SUM(cost_estimate) FROM workforce_shifts WHERE shift_date = d.d), 0)::numeric AS labour,
        COALESCE((SELECT SUM(value) FROM touchoffice_department_sales WHERE report_date = d.d), 0)::numeric AS sales
      FROM days d
    ) sub',
  '{}', 'shared', true, NOW(), 'u185', 'u185'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'occupancy_spark_7d',
  'Occupancy sparkline 7d',
  'U185: rooms-occupied count per day for sparkline.',
  E'SELECT array_agg(occupied::float ORDER BY d) AS values
    FROM (
      SELECT d.d, COALESCE(count(crn.*), 0) AS occupied
      FROM generate_series(CURRENT_DATE - 7, CURRENT_DATE - 1, ''1 day''::interval) d(d)
      LEFT JOIN caterbook_room_nights crn ON crn.night_date = d.d
      GROUP BY d.d
    ) sub',
  '{}', 'shared', true, NOW(), 'u185', 'u185'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

-- ── U186: today-vs-typical P10/P50/P90 ───────────────────────────────
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'revenue_today_vs_typical',
  'Revenue today vs typical range (P10/P50/P90 same DoW 90d)',
  'U186: drives the today-vs-typical band component. Today value + percentile against same-day-of-week history.',
  E'WITH today AS (
      SELECT
        COALESCE((SELECT SUM(value) FROM touchoffice_department_sales WHERE report_date = CURRENT_DATE), 0)
        + COALESCE((SELECT SUM(rate_per_night) FROM caterbook_room_nights WHERE night_date = CURRENT_DATE), 0) AS today_val
    ),
    dow_hist AS (
      SELECT EXTRACT(DOW FROM report_date)::int AS dow, report_date,
             SUM(value) +
             COALESCE((SELECT SUM(rate_per_night) FROM caterbook_room_nights WHERE night_date = ts.report_date), 0) AS daily
      FROM touchoffice_department_sales ts
      WHERE report_date BETWEEN CURRENT_DATE - 90 AND CURRENT_DATE - 1
      GROUP BY EXTRACT(DOW FROM report_date)::int, report_date
    ),
    band AS (
      SELECT
        PERCENTILE_CONT(0.10) WITHIN GROUP (ORDER BY daily)::numeric(12,2) AS p10,
        PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY daily)::numeric(12,2) AS p50,
        PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY daily)::numeric(12,2) AS p90,
        MIN(daily)::numeric(12,2) AS lo,
        MAX(daily)::numeric(12,2) AS hi
      FROM dow_hist
      WHERE dow = EXTRACT(DOW FROM CURRENT_DATE)::int
    )
    SELECT today_val::numeric(12,2) AS today, p10, p50, p90, lo, hi
      FROM today, band',
  '{}', 'shared', true, NOW(), 'u186', 'u186'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

-- ── U189: occupancy heatmap data ─────────────────────────────────────
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'occupancy_heatmap_28d',
  'Occupancy heatmap — 28 days × rooms',
  'U189: per (room, day) for next 28 days. 0/1 occupied flag drives heatmap intensity.',
  E'WITH days AS (
      SELECT generate_series(CURRENT_DATE, CURRENT_DATE + 27, ''1 day''::interval)::date AS d
    ),
    rooms AS (
      SELECT DISTINCT room FROM caterbook_room_nights
      WHERE night_date BETWEEN CURRENT_DATE - 60 AND CURRENT_DATE + 60
        AND room IS NOT NULL AND room <> ''''
    )
    SELECT
      r.room,
      d.d AS night,
      EXISTS(SELECT 1 FROM caterbook_room_nights crn
              WHERE crn.room = r.room AND crn.night_date = d.d) AS occupied,
      (SELECT rate_per_night FROM caterbook_room_nights crn
        WHERE crn.room = r.room AND crn.night_date = d.d LIMIT 1) AS rate
    FROM rooms r CROSS JOIN days d
    ORDER BY r.room, d.d',
  '{}', 'shared', true, NOW(), 'u189', 'u189'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

-- ── U190: stratified action queue with urgency_bucket ────────────────
CREATE OR REPLACE VIEW v_action_queue_stratified AS
  SELECT
    aq.*,
    CASE
      WHEN aq.severity = 'critical' OR aq.age_days > 7 THEN 'overdue'
      WHEN aq.age_days BETWEEN 1 AND 7 THEN 'this_week'
      WHEN aq.age_days = 0 THEN 'today'
      ELSE 'backlog'
    END AS urgency_bucket
  FROM v_action_queue aq;

INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'frontend_action_queue_stratified',
  'Action queue — stratified by urgency',
  'U190: action queue with urgency_bucket (overdue/today/this_week/backlog).',
  E'SELECT urgency_bucket, source, ref, severity, kind, title, age_date::text, age_days, realm
    FROM v_action_queue_stratified
    ORDER BY
      CASE urgency_bucket WHEN ''overdue'' THEN 1 WHEN ''today'' THEN 2 WHEN ''this_week'' THEN 3 ELSE 4 END,
      CASE severity WHEN ''critical'' THEN 1 WHEN ''high'' THEN 2 WHEN ''medium'' THEN 3 WHEN ''low'' THEN 4 ELSE 5 END,
      age_days DESC
    LIMIT 200',
  '{}', 'shared', true, NOW(), 'u190', 'u190'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

-- ── U192: anomaly z-score for week strip days ────────────────────────
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'week_strip_anomalies_7d',
  'Week-strip anomaly flags (|z| > 1.5 vs same-DoW history)',
  'U192: per-day z-score vs 90d same-DoW history. Outliers get amber border in week strip.',
  E'WITH days AS (
      SELECT generate_series(CURRENT_DATE - 6, CURRENT_DATE, ''1 day''::interval)::date AS d
    ),
    daily_today AS (
      SELECT d.d,
             COALESCE((SELECT SUM(value) FROM touchoffice_department_sales WHERE report_date = d.d), 0) AS daily
      FROM days d
    ),
    dow_stats AS (
      SELECT EXTRACT(DOW FROM report_date)::int AS dow,
             AVG(daily) AS mean, STDDEV_POP(daily) AS sd
      FROM (
        SELECT report_date, SUM(value) AS daily
        FROM touchoffice_department_sales
        WHERE report_date BETWEEN CURRENT_DATE - 90 AND CURRENT_DATE - 7
        GROUP BY report_date
      ) sub
      GROUP BY EXTRACT(DOW FROM report_date)::int
    )
    SELECT d.d AS day,
           dt.daily,
           ds.mean::numeric(12,2) AS dow_mean,
           ds.sd::numeric(12,2) AS dow_sd,
           CASE WHEN ds.sd > 0 THEN ROUND((dt.daily - ds.mean) / ds.sd, 2) END AS z_score,
           CASE WHEN ds.sd > 0 AND ABS((dt.daily - ds.mean) / ds.sd) > 1.5 THEN true ELSE false END AS anomalous
      FROM days d
      JOIN daily_today dt ON dt.d = d.d
      LEFT JOIN dow_stats ds ON ds.dow = EXTRACT(DOW FROM d.d)::int
      ORDER BY d.d',
  '{}', 'shared', true, NOW(), 'u192', 'u192'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

-- ── U196 + U197: Beer Garden + Ice Cream oracles ────────────────────
-- Simpler historical-only versions; weather API integration done in u196 script.
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'beer_garden_dow_baseline',
  'Beer garden baseline — same-DoW history (last 90d, sunny days)',
  'U196: historical food+drink revenue on same DoW. Compared against today by oracle script.',
  E'WITH dow_data AS (
      SELECT EXTRACT(DOW FROM report_date)::int AS dow, report_date, SUM(value) AS daily
        FROM touchoffice_department_sales
       WHERE report_date BETWEEN CURRENT_DATE - 90 AND CURRENT_DATE - 1
         AND site = ''malthouse''
       GROUP BY EXTRACT(DOW FROM report_date)::int, report_date
    )
    SELECT dow,
           ROUND(AVG(daily)::numeric, 2) AS avg_daily,
           ROUND(MAX(daily)::numeric, 2) AS max_daily,
           ROUND(MIN(daily)::numeric, 2) AS min_daily,
           count(*) AS sample_days
      FROM dow_data GROUP BY dow ORDER BY dow',
  '{}', 'shared', true, NOW(), 'u196', 'u196'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'cafe_demand_dow_baseline',
  'Cafe demand baseline — same-DoW history',
  'U197: historical cafe revenue + ice-cream sales on same DoW.',
  E'WITH dow_data AS (
      SELECT EXTRACT(DOW FROM report_date)::int AS dow, report_date, SUM(value) AS daily
        FROM touchoffice_department_sales
       WHERE report_date BETWEEN CURRENT_DATE - 90 AND CURRENT_DATE - 1
         AND site = ''sandwich''
       GROUP BY EXTRACT(DOW FROM report_date)::int, report_date
    )
    SELECT dow,
           ROUND(AVG(daily)::numeric, 2) AS avg_daily,
           ROUND(MAX(daily)::numeric, 2) AS max_daily,
           count(*) AS sample_days
      FROM dow_data GROUP BY dow ORDER BY dow',
  '{}', 'shared', true, NOW(), 'u197', 'u197'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

-- ── U198: container restart-storm ────────────────────────────────────
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'containers_restart_storm',
  'Containers restarted > 2× in last hour',
  'U198: surfaces container instability that docker ps masks (since restart-loops show Up).',
  E'SELECT ''placeholder''::text AS container,
           0::int AS restart_count,
           NOW() AS last_restart
     WHERE false  -- populated by u198-restart-watcher.sh into a real table; placeholder for now',
  '{}', 'shared', true, NOW(), 'u198', 'u198'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

COMMIT;
