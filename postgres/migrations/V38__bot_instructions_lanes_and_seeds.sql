-- ============================================================
-- U33 — bot_instructions lane columns + sender whitelist + SQL slug seeds
-- ============================================================
-- 1. Adds `lane`, `sender_email`, `needs_session` to bot_instructions so
--    the responder can split query-lane mail from data-lane mail and
--    flag the rows that need a human Claude Code session.
-- 2. Creates bot_sender_whitelist (who is allowed to ask questions) —
--    distinct from query_whitelist (which SQL templates can be run).
--    Both are read by the bot-responder.
-- 3. Seeds the 6 read-only slugs the responder advertises as tools to
--    Haiku. All slugs target Personal (entity_id=3) so the policy works
--    cleanly across sites; the SQL itself filters by site where needed.
-- ============================================================

-- ── 1. bot_instructions lane columns ────────────────────────
ALTER TABLE bot_instructions
  ADD COLUMN IF NOT EXISTS lane          TEXT NOT NULL DEFAULT 'query'
                                          CHECK (lane IN ('query','data','unknown')),
  ADD COLUMN IF NOT EXISTS sender_email  TEXT,
  ADD COLUMN IF NOT EXISTS needs_session BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_bi_lane_status ON bot_instructions (lane, status, received_at DESC);
CREATE INDEX IF NOT EXISTS idx_bi_needs_session ON bot_instructions (needs_session) WHERE needs_session;

-- Backfill sender_email from from_user for existing rows (best effort).
UPDATE bot_instructions
   SET sender_email = LOWER(
         CASE
           WHEN from_user ~ '<[^>]+@[^>]+>' THEN regexp_replace(from_user, '.*<([^>]+)>.*', '\1')
           WHEN from_user ~ '@'             THEN from_user
           ELSE NULL
         END)
 WHERE sender_email IS NULL;

-- ── 2. bot_sender_whitelist ─────────────────────────────────
CREATE TABLE IF NOT EXISTS bot_sender_whitelist (
  id            BIGSERIAL PRIMARY KEY,
  email         TEXT NOT NULL UNIQUE,
  display_name  TEXT,
  active        BOOLEAN NOT NULL DEFAULT TRUE,
  notes         TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by    TEXT NOT NULL DEFAULT 'bootstrap',
  entity_id     INT NOT NULL DEFAULT 3
);
CREATE INDEX IF NOT EXISTS idx_bsw_active_email ON bot_sender_whitelist (active, email);

ALTER TABLE bot_sender_whitelist ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS entity_isolation ON bot_sender_whitelist;
CREATE POLICY entity_isolation ON bot_sender_whitelist
  USING (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all'   THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$' THEN entity_id = current_setting('app.current_entity', true)::int
      ELSE false
    END)
  WITH CHECK (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all'   THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$' THEN entity_id = current_setting('app.current_entity', true)::int
      ELSE false
    END);

GRANT SELECT, INSERT, UPDATE, DELETE ON bot_sender_whitelist TO homeai_pipeline;
GRANT USAGE, SELECT ON bot_sender_whitelist_id_seq TO homeai_pipeline;
GRANT SELECT ON bot_sender_whitelist TO homeai_readonly;

-- Seed: Jo only, for now.
SET LOCAL app.current_entity = '3';
INSERT INTO bot_sender_whitelist (email, display_name, notes, created_by)
VALUES ('jolyon.sandercock@gmail.com', 'Jo Sandercock', 'Initial owner seed (U33).', 'V38')
ON CONFLICT (email) DO NOTHING;

-- ── 3. query_whitelist SQL slug seeds (6 rows) ──────────────
-- All approved at migration time by user='V38' so the router accepts them
-- immediately. Notes call out why each slug exists.

INSERT INTO query_whitelist (slug, display_name, description, intent_examples, sql_template, param_schema, result_format, created_by, approved_at, approved_by, notes)
VALUES
('today_totals',
 'Today''s totals across sites',
 'NET, GROSS and covers for today, split by pub vs sandwich bar, plus combined totals.',
 ARRAY[
   'what are today''s pub totals',
   'how did we do today',
   'today''s takings',
   'what''s today''s net so far',
   'pub totals today'
 ],
 $$SELECT report_date,
          pub_net_sales,      pub_gross_sales,      pub_covers,
          sandwich_net_sales, sandwich_gross_sales, sandwich_covers,
          total_net_sales,    total_gross_sales,    total_covers
     FROM v_daily_unit_economics
    WHERE report_date = CURRENT_DATE$$,
 '{}'::jsonb,
 'table',
 'V38', now(), 'V38',
 'Drives "how are we doing today" — the single hottest question.'),

('last_7d_unit_economics',
 'Last 7 days — daily unit economics',
 'Daily NET sales, covers, total revenue, labour % and SPLH for the past 7 days (today inclusive).',
 ARRAY[
   'how did we do last week',
   'last 7 days',
   'weekly summary',
   'recent unit economics',
   'show me last week''s performance'
 ],
 $$SELECT report_date, total_net_sales, total_covers, total_revenue,
          labour_pct, splh
     FROM v_daily_unit_economics
    WHERE report_date BETWEEN CURRENT_DATE - INTERVAL '6 days' AND CURRENT_DATE
    ORDER BY report_date DESC$$,
 '{}'::jsonb,
 'table',
 'V38', now(), 'V38',
 'Uses the materialised view — cheap.'),

('pending_invoices',
 'Vendor invoices awaiting processing',
 'Vendor invoices in the inbox that have not yet been linked to a Xero invoice.',
 ARRAY[
   'what invoices are pending',
   'unprocessed invoices',
   'invoices waiting',
   'open invoice inbox',
   'vendor invoices to process'
 ],
 $$SELECT vendor_domain, vendor_name, subject, received_at,
          amount_seen, currency, status
     FROM vendor_invoice_inbox
    WHERE linked_invoice_id IS NULL
      AND status IN ('new','extracted')
    ORDER BY received_at DESC
    LIMIT 50$$,
 '{}'::jsonb,
 'table',
 'V38', now(), 'V38',
 'Capped at 50 — if more, ask a narrower question.'),

('latest_caterbook_occupancy',
 'Most recent Caterbook occupancy snapshot',
 'Latest in-house, arrivals, stayovers, departures from the Caterbook daily snapshot feed.',
 ARRAY[
   'how full are we',
   'occupancy',
   'who''s arriving today',
   'accommodation status',
   'rooms in house'
 ],
 $$SELECT report_date, in_house_count, revenue_in_house,
          arrivals_count, stayovers_count, departures_count
     FROM caterbook_daily_snapshots
    ORDER BY report_date DESC
    LIMIT 1$$,
 '{}'::jsonb,
 'table',
 'V38', now(), 'V38',
 'Single row — pull arrivals/departures lists via a follow-up slug if needed.'),

('recent_alerts',
 'Recent firing system alerts',
 'System alerts updated in the last :hours hours (default 24).',
 ARRAY[
   'any alerts',
   'what''s broken',
   'recent alerts',
   'show me alerts from the last 6 hours',
   'is anything firing'
 ],
 $$SELECT alertname, severity, status, summary,
          starts_at, acknowledged
     FROM system_alerts
    WHERE last_updated_at >= NOW() - make_interval(hours => :hours)
    ORDER BY starts_at DESC
    LIMIT 50$$,
 '{"hours": {"type":"int","required":false,"default":24,"min":1,"max":720}}'::jsonb,
 'table',
 'V38', now(), 'V38',
 'Parameter validated against schema before bind.'),

('entity_summary',
 'Entity summary',
 'Quick snapshot for an entity: name plus counts of pending instructions and documents.',
 ARRAY[
   'tell me about entity 1',
   'entity summary',
   'what''s the state of malthouse',
   'how is the trading company doing'
 ],
 $$SELECT e.id,
          e.name,
          (SELECT COUNT(*) FROM bot_instructions  bi WHERE bi.entity_id = e.id AND bi.status = 'pending') AS pending_instructions,
          (SELECT COUNT(*) FROM documents          d WHERE d.entity_id  = e.id)                            AS doc_count,
          (SELECT COUNT(*) FROM system_alerts      a WHERE a.status = 'firing' AND a.acknowledged = false) AS firing_alerts_global
     FROM entities e
    WHERE e.id = :entity_id$$,
 '{"entity_id": {"type":"int","required":true,"min":1,"max":99}}'::jsonb,
 'table',
 'V38', now(), 'V38',
 'firing_alerts_global is global — system_alerts has no entity_id column.')
ON CONFLICT (slug) DO NOTHING;
