#!/usr/bin/env bash
# u294-derive-sender-denylist.sh — data-driven invoice-sender denylist.
#
# Derives invoice_sender_rules (V291) from 90 days of routing evidence and
# refreshes static_context['invoice.sender_denylist'] which the gmail-ingest
# classifier reads (u293/u295). Safety model:
#   AUTO-DENY  : >=5 invoice-classified, 0 PDF attachments, 0 captured invoices
#                = body-only notification sender, nothing to lose.
#   REVIEW     : >=5 classified, HAS PDF attachments, 0 captured = possible real
#                supplier with broken capture (or statements) — NOT enforced,
#                surfaced for a human. This is the guard against silently
#                dropping a real supplier.
#   SELF-HEAL  : an auto-deny sender that later captures a real invoice is
#                removed automatically (survives a capture outage).
#   ALLOW/manual rules always win and are never auto-touched.
#
# Cron: daily. Idempotent. Emits a heartbeat + summary.
set -euo pipefail
echo "START u294-derive-sender-denylist $(date -u +%FT%TZ)"

docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
SET LOCAL app.current_entity='all';
SET LOCAL app.current_realm='owner';

-- 90-day per-sender routing evidence
CREATE TEMP TABLE _cand ON COMMIT DROP AS
WITH inv AS (
  SELECT lower(em.from_address) AS sender, e.payload->>'gmail_message_id' AS mid
    FROM events e JOIN emails em ON em.gmail_message_id = e.payload->>'gmail_message_id'
   WHERE e.event_type='invoice.detected'
     AND e.created_at > now() - interval '90 days'
     AND em.from_address IS NOT NULL AND em.from_address <> ''
)
SELECT sender,
       split_part(sender,'@',2) AS domain,
       count(*) AS classified,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM events d
                 WHERE d.event_type='document.received'
                   AND d.payload->>'gmail_message_id'=inv.mid)) AS with_attachment,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM vendor_invoice_inbox v
                 WHERE v.source_email_id=inv.mid AND v.gross_amount IS NOT NULL)) AS captured
  FROM inv GROUP BY sender;

-- SELF-HEAL: an auto-deny sender that now captures real invoices is not spam.
DELETE FROM invoice_sender_rules r
 USING _cand c
 WHERE r.source='auto' AND r.action='deny'
   AND r.match_type='address' AND r.sender=c.sender
   AND c.captured > 0;

-- AUTO-DENY: body-only notification senders (0 attachment, 0 captured, >=5),
-- unless the address or its domain is explicitly allow-ruled.
INSERT INTO invoice_sender_rules (sender, match_type, action, source, reason, evidence)
SELECT c.sender, 'address', 'deny', 'auto',
       'auto: '||c.classified||' invoice-classified, 0 attachment, 0 captured (90d)',
       jsonb_build_object('classified',c.classified,'with_attachment',0,'real_captured',0,'window_days',90)
  FROM _cand c
 WHERE c.classified >= 5 AND c.with_attachment = 0 AND c.captured = 0
   AND NOT EXISTS (SELECT 1 FROM invoice_sender_rules a WHERE a.action='allow'
                     AND ((a.match_type='address' AND a.sender=c.sender)
                       OR (a.match_type='domain'  AND a.sender=c.domain)))
ON CONFLICT (sender, match_type) DO UPDATE
   SET evidence=EXCLUDED.evidence, updated_at=now()
 WHERE invoice_sender_rules.action='deny' AND invoice_sender_rules.source='auto';

-- REVIEW: PDF-bearing but 0 captured — do NOT enforce, surface for a human.
INSERT INTO invoice_sender_rules (sender, match_type, action, source, reason, evidence)
SELECT c.sender, 'address', 'review', 'auto',
       'auto-review: '||c.classified||' classified, '||c.with_attachment||' with PDF, 0 captured (90d) — real supplier w/ broken capture, or statements?',
       jsonb_build_object('classified',c.classified,'with_attachment',c.with_attachment,'real_captured',0,'window_days',90)
  FROM _cand c
 WHERE c.classified >= 5 AND c.with_attachment > 0 AND c.captured = 0
   AND NOT EXISTS (SELECT 1 FROM invoice_sender_rules r WHERE r.sender=c.sender AND r.match_type='address')
ON CONFLICT (sender, match_type) DO NOTHING;

-- Rebuild the denylist the classifier reads (V292: shared with the dashboard
-- sender-rules-review actions, so cron and UI can't drift).
SELECT home_ai.rebuild_sender_denylist();

-- Summary + audit heartbeat
\echo 'rule counts:'
SELECT action, source, count(*) FROM invoice_sender_rules GROUP BY 1,2 ORDER BY 1,2;
\echo 'review queue (needs a human):'
SELECT sender, evidence->>'classified' AS classified, evidence->>'with_attachment' AS pdfs
  FROM invoice_sender_rules WHERE action='review' ORDER BY (evidence->>'classified')::int DESC;

INSERT INTO audit_log (pipeline, action, pipeline_version, result, ai_parsed)
SELECT 'invoice_sender_denylist','derive','1.0','success',
       jsonb_build_object(
         'deny_total',   (SELECT count(*) FROM invoice_sender_rules WHERE action='deny'),
         'review_total', (SELECT count(*) FROM invoice_sender_rules WHERE action='review'),
         'allow_total',  (SELECT count(*) FROM invoice_sender_rules WHERE action='allow'));
COMMIT;
SQL

echo "DONE u294-derive-sender-denylist $(date -u +%FT%TZ)"
