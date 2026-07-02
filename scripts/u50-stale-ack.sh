#!/bin/bash
# /home_ai/scripts/u50-stale-ack.sh
#
# T4 of U50. Auto-acks Diag_* alerts older than 12h that nobody resolved.
# These re-fire daily at 06:30 from a detector with no resolution logic
# (see memory feedback_telegram_heartbeat). Real alerts (non-Diag_*) are
# untouched.
#
# Cron: 06:25 and 18:25 daily.

set -uo pipefail
DRY="${1:-}"

docker exec -i homeai-postgres psql -U postgres -d homeai <<SQL
SET app.current_entity='all';

WITH stale AS (
  SELECT id, alertname, last_updated_at
    FROM system_alerts
   WHERE alertname LIKE 'Diag\\_%' ESCAPE '\\'
     AND status='firing'
     AND acknowledged=false
     AND last_updated_at < now() - interval '12 hours'
)
SELECT count(*) AS to_ack FROM stale;

UPDATE system_alerts
   SET acknowledged=true,
       acknowledged_by='u50-stale-ack',
       acknowledged_at=now(),
       notes = COALESCE(notes, '') ||
               CASE WHEN notes IS NULL OR notes='' THEN '' ELSE E'\n' END ||
               'auto-acked stale by U50 ' || to_char(now(),'YYYY-MM-DD HH24:MI')
 WHERE alertname LIKE 'Diag\\_%' ESCAPE '\\'
   AND status='firing'
   AND acknowledged=false
   AND last_updated_at < now() - interval '12 hours';

-- R0.3: auto-resolve ANY firing alert (not just Diag_*) not refreshed in 72h.
-- The digest task trusts status='firing' as "currently live" — stale rows
-- that stopped being refreshed (detector removed/renamed, one-off blip)
-- must not linger forever. Keys on last_updated_at (refresh timestamp),
-- not starts_at, so genuinely-live alerts that keep upserting survive.
UPDATE system_alerts SET status='resolved', ends_at=now(),
       notes=COALESCE(notes,'')||' [auto-resolved: not refreshed >72h, R0.3]'
 WHERE status='firing' AND last_updated_at < now() - interval '72 hours';
SQL
