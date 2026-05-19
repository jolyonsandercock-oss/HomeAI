-- =============================================================================
-- V158 — U135 T8: backend health slugs
-- =============================================================================

BEGIN;

INSERT INTO query_whitelist
    (slug, display_name, description, sql_template, param_schema, result_format,
     active, created_by, approved_at, approved_by, notes, realm)
VALUES
    -- AI usage rollup for last 24h (cost left out — no per-model pricing
    -- constants in DB yet; surface tokens + latency).
    ('backend_ai_usage_24h',
     'AI usage — last 24h',
     'Per-model rollup of token usage + latency over the trailing 24h.',
     $sql$SELECT model_used,
                tier,
                COUNT(*) AS call_count,
                SUM(prompt_tokens)     AS prompt_tokens,
                SUM(completion_tokens) AS completion_tokens,
                ROUND(AVG(latency_ms))::int AS avg_latency_ms,
                COUNT(*) FILTER (WHERE cached) AS cache_hits,
                COUNT(*) FILTER (WHERE escalated) AS escalated
           FROM ai_usage
          WHERE timestamp >= NOW() - INTERVAL '24 hours'
          GROUP BY model_used, tier
          ORDER BY SUM(prompt_tokens) + SUM(completion_tokens) DESC$sql$,
     '{}'::jsonb, 'table', true, 'V158-U135T8', NOW(), 'V158-U135T8',
     'Per U135 T8 plan.', 'work'),

    -- Errors in audit_log over last 24h, grouped by pipeline + action
    ('backend_errors_24h',
     'Backend errors — last 24h',
     'audit_log rows whose action ends ":firing" or contains "error" / "fail" / "stuck" / "stale", over the trailing 24h.',
     $sql$SELECT pipeline,
                action,
                COUNT(*) AS occurrences,
                max(created_at) AS most_recent
           FROM audit_log
          WHERE created_at >= NOW() - INTERVAL '24 hours'
            AND (action LIKE '%firing'
                 OR action ILIKE '%error%'
                 OR action ILIKE '%fail%'
                 OR action ILIKE '%stuck%'
                 OR action ILIKE '%stale%'
                 OR action ILIKE '%dead_letter%')
          GROUP BY pipeline, action
          ORDER BY most_recent DESC$sql$,
     '{}'::jsonb, 'table', true, 'V158-U135T8', NOW(), 'V158-U135T8',
     'Per U135 T8 plan.', 'work'),

    -- Import freshness — Dojo, Tanda, TouchOffice
    ('backend_import_freshness',
     'Import freshness — Dojo / Tanda / TouchOffice',
     'How recent each upstream sync is. Drives the "stalled imports" red banner.',
     $sql$SELECT 'dojo'        AS source,
                (SELECT last_tx FROM v_dojo_freshness)::text AS last_data,
                (SELECT ROUND(hours_stale::numeric,1) FROM v_dojo_freshness) AS hours_stale
          UNION ALL
          SELECT 'tanda_users',
                 (SELECT max(last_synced_at)::text FROM workforce_users),
                 (SELECT ROUND(EXTRACT(EPOCH FROM (NOW() - max(last_synced_at)))/3600::numeric, 1)
                    FROM workforce_users)
          UNION ALL
          SELECT 'tanda_shifts',
                 (SELECT max(shift_date)::text FROM workforce_shifts),
                 (SELECT ROUND(EXTRACT(EPOCH FROM (NOW() - max(shift_date)::timestamp))/3600::numeric, 1)
                    FROM workforce_shifts WHERE shift_date <= CURRENT_DATE)
          UNION ALL
          SELECT 'touchoffice',
                 (SELECT max(report_date)::text FROM touchoffice_department_sales),
                 (SELECT ROUND(EXTRACT(EPOCH FROM (NOW() - max(report_date)::timestamp))/3600::numeric, 1)
                    FROM touchoffice_department_sales)$sql$,
     '{}'::jsonb, 'table', true, 'V158-U135T8', NOW(), 'V158-U135T8',
     'Per U135 T8 plan.', 'work')
ON CONFLICT (slug) DO UPDATE
   SET sql_template = EXCLUDED.sql_template,
       active       = true,
       approved_at  = NOW();

COMMIT;
