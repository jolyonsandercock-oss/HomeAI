-- =============================================================================
-- V187 — U165: operational observability slugs
-- =============================================================================
-- Three slugs powering the proactive watcher: catches drift before Jo notices.
-- =============================================================================

BEGIN;

-- ── pipeline_health_per_day ──────────────────────────────────────────
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'pipeline_health_per_day',
  'Pipeline health — last 7 days',
  'U165: per-workflow runs + success rate + p50/p95 duration for last 7d.',
  E'SELECT
      w.name AS workflow,
      DATE(e."startedAt") AS day,
      count(*) AS runs,
      count(*) FILTER (WHERE e.status = ''success'')::numeric / count(*)::numeric * 100 AS success_pct,
      percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (e."stoppedAt" - e."startedAt")))::int AS p50_ms,
      percentile_cont(0.95) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (e."stoppedAt" - e."startedAt")))::int AS p95_ms
    FROM execution_entity e
    JOIN workflow_entity w ON w.id = e."workflowId"
   WHERE e."startedAt" > NOW() - INTERVAL ''7 days''
   GROUP BY w.name, DATE(e."startedAt")
   ORDER BY DATE(e."startedAt") DESC, w.name',
  '{}', 'shared', true, NOW(), 'u165', 'u165'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

-- ── data_source_freshness ──────────────────────────────────────────
-- expected_cadence_hours: how often this source SHOULD update (rough)
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'data_source_freshness',
  'Data source freshness — staleness audit',
  'U165: per upstream source, max(timestamp) vs expected cadence. Flags stale > 2x cadence.',
  E'WITH sources AS (
      SELECT ''gmail''                       AS source, (SELECT max(received_at) FROM emails)                    AS latest, 1   AS expected_h
      UNION ALL SELECT ''caterbook'',         (SELECT max(report_date)::timestamptz FROM caterbook_daily_snapshots), 24
      UNION ALL SELECT ''dojo'',              (SELECT max(transaction_date)::timestamptz FROM dojo_transactions),    24
      UNION ALL SELECT ''touchoffice_dept'',  (SELECT max(report_date)::timestamptz FROM touchoffice_department_sales), 24
      UNION ALL SELECT ''touchoffice_plu'',   (SELECT max(report_date)::timestamptz FROM touchoffice_plu_sales),    24
      UNION ALL SELECT ''xero'',              (SELECT max(ingested_at)               FROM xero_bills),              168
      UNION ALL SELECT ''accommodation_bookings'', (SELECT max(updated_at)           FROM accommodation_bookings), 6
      UNION ALL SELECT ''restaurant_reservations'', (SELECT max(created_at)          FROM restaurant_reservations), 6
      UNION ALL SELECT ''tide_times'',        (SELECT max(scraped_at)                FROM tide_times),             24
      UNION ALL SELECT ''guest_reviews'',     (SELECT max(scraped_at)                FROM guest_reviews),          24
      UNION ALL SELECT ''trail_reports'',     (SELECT max(report_date)::timestamptz  FROM trail_reports),          24
      UNION ALL SELECT ''vendor_invoice_inbox'', (SELECT max(received_at)            FROM vendor_invoice_inbox),    6
    )
    SELECT
      source,
      latest,
      expected_h AS expected_hours,
      EXTRACT(EPOCH FROM (NOW() - latest))/3600 AS age_h,
      CASE
        WHEN latest IS NULL THEN ''never''
        WHEN EXTRACT(EPOCH FROM (NOW() - latest))/3600 > expected_h * 2 THEN ''stale''
        WHEN EXTRACT(EPOCH FROM (NOW() - latest))/3600 > expected_h     THEN ''warn''
        ELSE ''ok''
      END AS status
    FROM sources
    ORDER BY status, age_h DESC NULLS FIRST',
  '{}', 'shared', true, NOW(), 'u165', 'u165'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

-- ── cost_by_capability_30d ──────────────────────────────────────────
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'cost_by_capability_30d',
  'AI cost by capability — last 30 days',
  'U165: per capability_tag spend + utilization vs tier ceiling.',
  E'WITH usage AS (
      SELECT
        capability_tag,
        business_priority AS tier,
        count(*) AS calls,
        SUM(cost_gbp)::numeric(10,4) AS spent_gbp,
        SUM(prompt_tokens) AS prompt_toks,
        SUM(cache_read_tokens) AS cache_read,
        AVG(latency_ms)::int AS avg_latency_ms
      FROM ai_usage
      WHERE timestamp > NOW() - INTERVAL ''30 days''
      GROUP BY capability_tag, business_priority
    ),
    tier_ceilings AS (
      SELECT business_priority AS tier, daily_cost_ceiling_gbp * 30 AS month_ceiling
      FROM quota_allocations
    )
    SELECT
      COALESCE(u.capability_tag, ''(untagged)'')   AS capability_tag,
      u.tier,
      u.calls,
      u.spent_gbp,
      u.prompt_toks,
      u.cache_read,
      CASE WHEN (u.prompt_toks + u.cache_read) > 0 THEN
        ROUND(100.0 * u.cache_read / (u.prompt_toks + u.cache_read), 1)
        ELSE NULL END AS cache_hit_pct,
      u.avg_latency_ms,
      t.month_ceiling,
      CASE WHEN t.month_ceiling > 0 THEN
        ROUND(100.0 * u.spent_gbp / t.month_ceiling, 1)
        ELSE NULL END AS pct_of_tier_month
    FROM usage u
    LEFT JOIN tier_ceilings t ON t.tier = u.tier
    ORDER BY u.spent_gbp DESC NULLS LAST',
  '{}', 'shared', true, NOW(), 'u165', 'u165'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

COMMIT;
