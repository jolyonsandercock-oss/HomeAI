-- V287: Frontend F1 — read-slugs for the new /app/ops pipeline-health board
-- (ops_freshness / ops_alerts / ops_recent_failures) and the /app/reviews
-- tracker (reviews_source_health / reviews_blend; reviews_recent already
-- exists from V147). All realm='work', read-only, LIMIT-bounded.
-- Idempotent: ON CONFLICT (slug) DO UPDATE refreshes the template.

INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, result_format,
   active, entity_id, created_by, approved_at, approved_by, realm)
VALUES
(
  'ops_freshness',
  'Ops — pipeline freshness (SLA traffic lights)',
  'Every registered pipeline vs its freshness SLA via ops.check_freshness(). STALE first, then NO_DATA, then ok.',
  $sql$
  SELECT name, status, age_hours, sla_hours
    FROM ops.check_freshness()
   ORDER BY CASE status WHEN 'STALE' THEN 0 WHEN 'NO_DATA' THEN 1 ELSE 2 END,
            age_hours DESC NULLS FIRST
   LIMIT 80
  $sql$,
  '{}'::jsonb, 'table', true, 3, 'V287-F1', now(), 'V287-F1', 'work'
),
(
  'ops_alerts',
  'Ops — firing system alerts',
  'Currently-firing rows from system_alerts (watchdogs, Alertmanager sink), newest first.',
  $sql$
  SELECT alertname, severity, status, starts_at, acknowledged,
         LEFT(COALESCE(summary, description, ''), 200) AS summary
    FROM system_alerts
   WHERE status = 'firing'
   ORDER BY starts_at DESC
   LIMIT 20
  $sql$,
  '{}'::jsonb, 'table', true, 3, 'V287-F1', now(), 'V287-F1', 'work'
),
(
  'ops_recent_failures',
  'Ops — pipeline failures (24h)',
  'Failed ops.pipeline_runs rows in the last 24 hours, newest first.',
  $sql$
  SELECT name, started_at, finished_at, status, rows_affected,
         LEFT(COALESCE(note, ''), 200) AS note
    FROM ops.pipeline_runs
   WHERE status = 'failed'
     AND finished_at >= now() - interval '24 hours'
   ORDER BY finished_at DESC
   LIMIT 20
  $sql$,
  '{}'::jsonb, 'table', true, 3, 'V287-F1', now(), 'V287-F1', 'work'
),
(
  'reviews_source_health',
  'Reviews — per-source aggregator health',
  'Per-source review count + last review, FULL JOINed to review_listings so dead scrapers (google unparsed, tripadvisor fetch_fail) and scraper-less sources (booking_com email-ingest) all surface.',
  $sql$
  SELECT COALESCE(g.source, l.source) AS source,
         l.location, l.active, l.last_scraped_at, l.last_status,
         COALESCE(g.n, 0) AS review_count, g.last_review_at
    FROM (SELECT source, COUNT(*) AS n, MAX(posted_at) AS last_review_at
            FROM guest_reviews GROUP BY source) g
    FULL JOIN review_listings l ON l.source = g.source
   ORDER BY 1, l.location NULLS LAST
   LIMIT 40
  $sql$,
  '{}'::jsonb, 'table', true, 3, 'V287-F1', now(), 'V287-F1', 'work'
),
(
  'reviews_blend',
  'Reviews — blended headline rating (/5 normalised)',
  'Single blended average across all sources, booking_com + expedia /10 folded to /5 (same convention as reviews_three_source_summary per V277). All-time + 30d.',
  $sql$
  WITH norm AS (
    SELECT CASE WHEN source IN ('booking_com','expedia')
                THEN rating::numeric / 2.0
                ELSE rating::numeric END AS rating5,
           posted_at
      FROM guest_reviews
     WHERE rating IS NOT NULL
  )
  SELECT ROUND(AVG(rating5), 2)  AS blended_all_time,
         COUNT(*)                AS count_all_time,
         ROUND(AVG(rating5) FILTER (WHERE posted_at >= now() - interval '30 days'), 2) AS blended_30d,
         COUNT(*) FILTER (WHERE posted_at >= now() - interval '30 days')               AS count_30d
    FROM norm
  $sql$,
  '{}'::jsonb, 'table', true, 3, 'V287-F1', now(), 'V287-F1', 'work'
)
ON CONFLICT (slug) DO UPDATE
   SET sql_template = EXCLUDED.sql_template,
       display_name = EXCLUDED.display_name,
       description  = EXCLUDED.description,
       realm        = EXCLUDED.realm,
       active       = true;
