-- Escalation shadow scoreboard: does local gemma-heavy agree with the cloud
-- answer on the real escalations? For classify tasks we compare the parsed
-- 'category'; for extraction we compare JSON validity as a first cut.
SET app.current_entity='all'; SET app.current_realm='owner';
SELECT
  task_type,
  count(*)                                                          AS escalations,
  count(*) FILTER (WHERE shadow_error IS NOT NULL)                  AS shadow_failed,
  count(*) FILTER (WHERE shadow_text IS NOT NULL
                   AND shadow_text::text ~ '^\s*\{')                AS shadow_valid_json,
  count(*) FILTER (WHERE
      lower(coalesce(nullif(regexp_replace(shadow_text,'.*"category"\s*:\s*"([a-z-]+)".*','\1','s'),shadow_text),'')) =
      lower(coalesce(nullif(regexp_replace(cloud_text ,'.*"category"\s*:\s*"([a-z-]+)".*','\1','s'),cloud_text ),''))
      AND cloud_text ~ '"category"'
    )                                                               AS category_agree,
  round(avg(shadow_latency_ms))                                     AS avg_shadow_ms
FROM escalation_shadow
GROUP BY task_type ORDER BY escalations DESC;
