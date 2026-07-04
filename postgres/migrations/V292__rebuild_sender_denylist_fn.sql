-- V292 (2026-07-04) — single source of truth for the sender denylist cache.
-- Both u294 (daily cron) and the dashboard sender-rules-review actions call
-- this, so static_context['invoice.sender_denylist'] can never drift between
-- the cron and the UI. Regenerates the cache from invoice_sender_rules
-- (action='deny' minus allow overrides) and returns the current counts.

CREATE OR REPLACE FUNCTION home_ai.rebuild_sender_denylist()
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  result jsonb;
BEGIN
  WITH deny AS (
    SELECT d.sender, d.match_type
      FROM invoice_sender_rules d
     WHERE d.action='deny'
       AND NOT EXISTS (
         SELECT 1 FROM invoice_sender_rules a
          WHERE a.action='allow'
            AND ((a.match_type='address' AND a.sender=d.sender)
              OR (a.match_type='domain'  AND a.sender=split_part(d.sender,'@',2))))
  )
  INSERT INTO static_context (key, value, updated_at, realm)
  VALUES ('invoice.sender_denylist',
          jsonb_build_object(
            'addresses',    (SELECT coalesce(jsonb_agg(sender ORDER BY sender),'[]'::jsonb) FROM deny WHERE match_type='address'),
            'domains',      (SELECT coalesce(jsonb_agg(sender ORDER BY sender),'[]'::jsonb) FROM deny WHERE match_type='domain'),
            'refreshed_at', now()::text),
          now(), 'owner')
  ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value, updated_at=now();

  SELECT jsonb_build_object(
           'deny',   count(*) FILTER (WHERE action='deny'),
           'allow',  count(*) FILTER (WHERE action='allow'),
           'review', count(*) FILTER (WHERE action='review'))
    INTO result FROM invoice_sender_rules;
  RETURN result;
END
$$;

COMMENT ON FUNCTION home_ai.rebuild_sender_denylist() IS
  'Regenerate static_context[invoice.sender_denylist] from invoice_sender_rules (deny minus allow overrides); returns {deny,allow,review} counts. Called by u294 cron + dashboard sender-rules-review (V292).';
