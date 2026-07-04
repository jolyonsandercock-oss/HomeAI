-- B3_UPSERT_v2 (u292, 2026-07-04) parameterized P9 write.
-- NOTE: this query text must contain NO dollar-number tokens anywhere except
-- the real placeholders (one..nine) below -- n8n's pg-promise scans the WHOLE
-- string, COMMENTS INCLUDED, for dollar-N bind vars. The old node inlined the
-- extracted document text; a quote whose text held a dollar-prefixed number
-- (e.g. quote_4835141.pdf) put that token into the assembled string, and
-- pg-promise read it as a bind variable index far past its maximum, failing
-- EVERY document whose text contains a dollar-prefixed number. Free-text and
-- string fields are now bound as positional params, the same fix
-- p2-parameterize-write.py applied to P2's write node. Dollar-quote tags
-- protected Postgres's parser but NOT pg-promise's pre-scan -- hence the trap.
WITH resolved_email AS (
  SELECT id AS email_id FROM emails
   WHERE gmail_message_id = $1
   LIMIT 1
),
upserted AS (
  INSERT INTO email_attachments
    (email_id, event_id, filename, mime_type, extracted_text, processed)
  VALUES
    ((SELECT email_id FROM resolved_email),
     $2, $3, $4, $5, true)
  RETURNING id
)
INSERT INTO audit_log
  (pipeline, event_id, trace_id, action, record_type, record_id,
   ai_worker, ai_model, ai_raw_output, ai_parsed,
   pipeline_version, result, provider)
SELECT 'report_ingestion',
       $2,
       $6::uuid,
       'classify_document',
       'email_attachment',
       (SELECT id FROM upserted),
       'report_parser',
       'claude-haiku-4-5-20251001',
       $7,
       $8::jsonb,
       '1.0',
       $9,
       'anthropic'
RETURNING id AS audit_id;
