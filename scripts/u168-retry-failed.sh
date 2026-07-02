#!/bin/bash
# /home_ai/scripts/u168-retry-failed.sh
# U168 watcher — runs every 15 min, retries any failed job within its
# grace_minutes window provided attempt < max_retries.

set -euo pipefail
LOG=/home_ai/logs/u168-retry.log

# Find failed jobs that are retryable
RETRYABLE=$(docker exec homeai-postgres psql -U postgres -d homeai -tAc "
SELECT r.id, r.job_name, c.command, r.attempt, c.max_retries, c.grace_minutes
  FROM cron_job_runs r
  JOIN cron_job_catalog c ON c.job_name = r.job_name
 WHERE r.status = 'failed'
   AND r.attempt < c.max_retries
   AND r.expected_at > NOW() - (c.grace_minutes::text || ' minutes')::interval
   AND NOT EXISTS (
     SELECT 1 FROM cron_job_runs r2
      WHERE r2.job_name = r.job_name
        AND r2.expected_at::date = r.expected_at::date
        AND r2.status = 'success'
   )
ORDER BY r.expected_at;")

if [ -z "$RETRYABLE" ]; then
  echo "$(date -Iseconds)  no jobs to retry" >> "$LOG"
  exit 0
fi

echo "$RETRYABLE" | while IFS='|' read -r RUN_ID JOB_NAME CMD ATTEMPT MAX_RETRIES GRACE; do
  [ -z "$JOB_NAME" ] && continue
  NEXT_ATTEMPT=$((ATTEMPT + 1))
  echo "$(date -Iseconds)  retrying $JOB_NAME (attempt $NEXT_ATTEMPT/$MAX_RETRIES)" >> "$LOG"

  # Mark prior row as 'retried' to avoid double-retry. If this fails, skip this
  # job for this cycle rather than risk retrying it twice (it'll be picked up
  # again next run since its status is untouched).
  if ! docker exec -i homeai-postgres psql -U postgres -d homeai -c "
  UPDATE cron_job_runs SET status='retried' WHERE id=$RUN_ID;" >/dev/null; then
    echo "$(date -Iseconds)  WARN: failed to mark run $RUN_ID retried — skipping $JOB_NAME this cycle" >> "$LOG"
    continue
  fi

  # Re-run via the wrapper, attempt counter bumped
  EXPECTED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  LOG_TMP=$(mktemp)
  NEW_ID=$(docker exec -i homeai-postgres psql -U postgres -d homeai -tAc "
  INSERT INTO cron_job_runs (job_name, expected_at, started_at, status, attempt)
  VALUES ('$JOB_NAME', '$EXPECTED_AT'::timestamptz, NOW(), 'running', $NEXT_ATTEMPT)
  RETURNING id;") || NEW_ID=""
  if [ -z "$NEW_ID" ]; then
    echo "$(date -Iseconds)  WARN: failed to insert cron_job_runs row for $JOB_NAME — skipping" >> "$LOG"
    rm -f "$LOG_TMP"
    continue
  fi

  # The retried command legitimately may fail again — that's a normal outcome
  # here (not a script bug), so it must not abort the loop under set -e.
  RC=0
  eval "$CMD" > "$LOG_TMP" 2>&1 || RC=$?
  EXC=$(tail -50 "$LOG_TMP" | head -c 4000 | sed "s/'/''/g")
  [ $RC -eq 0 ] && ST=success || ST=failed
  docker exec -i homeai-postgres psql -U postgres -d homeai -c "
  UPDATE cron_job_runs SET completed_at=NOW(), status='$ST', exit_code=$RC, log_excerpt='$EXC'
   WHERE id=$NEW_ID;" >/dev/null || echo "$(date -Iseconds)  WARN: failed to record final status for run $NEW_ID" >> "$LOG"

  echo "$(date -Iseconds)  $JOB_NAME attempt $NEXT_ATTEMPT → $ST (rc=$RC)" >> "$LOG"
  rm -f "$LOG_TMP"
done
