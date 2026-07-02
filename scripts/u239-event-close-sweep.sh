#!/usr/bin/env bash
# u239-event-close-sweep.sh — STOPGAP for the noOp-skip bug: gmail-ingest
# ingests emails but doesn't always mark its event 'processed', so events
# reprocess forever. This closes email.received events whose email is already
# in the emails table (idempotent, safe). Remove once the pipeline reliably
# marks its own events. Runs every 5 min.
set -euo pipefail
docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 <<SQL
BEGIN; SET LOCAL app.current_entity='all'; SET LOCAL app.current_realm='owner';
UPDATE events SET status='processed', processed_at=COALESCE(processed_at, NOW())
 WHERE event_type='email.received' AND status IN ('pending','processing')
   AND payload->>'gmail_message_id' IN (SELECT gmail_message_id FROM emails);
COMMIT;
SQL
