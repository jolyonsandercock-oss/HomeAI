#!/bin/bash
# /home_ai/scripts/u168-cron-wrapper.sh
# Wraps a cron command with cron_job_runs tracking.
# Usage: u168-cron-wrapper.sh <job_name> <command>
#
# Records run in cron_job_runs with exit code + log excerpt. Watcher
# (u168-retry-failed.sh) picks up failed runs within their grace window.

set -euo pipefail

JOB_NAME="${1:-?}"
shift
CMD="$*"

EXPECTED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
LOG_TMP=$(mktemp)
trap "rm -f $LOG_TMP" EXIT

# Insert pending row
RUN_ID=$(docker exec -i homeai-postgres psql -U postgres -d homeai -tAc "
INSERT INTO cron_job_runs (job_name, expected_at, started_at, status)
VALUES ('$JOB_NAME', '$EXPECTED_AT'::timestamptz, NOW(), 'running')
RETURNING id;")

# Run the command. The whole point of this wrapper is to record whether the
# wrapped command failed — under set -e a bare `eval ... ; EXIT_CODE=$?` would
# abort HERE on any failing command, before the cron_job_runs row is ever
# updated, leaving it stuck at status='running' forever and hiding the
# failure from u168-retry-failed.sh. Capture the real exit code without
# letting -e trigger.
eval "$CMD" > "$LOG_TMP" 2>&1 && EXIT_CODE=0 || EXIT_CODE=$?

# Tail the output
LOG_EXCERPT=$(tail -50 "$LOG_TMP" | head -c 4000 | sed "s/'/''/g")

if [ "$EXIT_CODE" -eq 0 ]; then
  STATUS=success
else
  STATUS=failed
fi

# A failure recording this row must not override the wrapped command's own
# EXIT_CODE (below) nor suppress the log propagation that follows.
docker exec -i homeai-postgres psql -U postgres -d homeai -c "
UPDATE cron_job_runs
   SET completed_at = NOW(), status = '$STATUS', exit_code = $EXIT_CODE,
       log_excerpt = '$LOG_EXCERPT'
 WHERE id = $RUN_ID;" >/dev/null || echo "u168-cron-wrapper: WARN failed to record run $RUN_ID status" >&2

# Propagate output to cron
cat "$LOG_TMP"
exit $EXIT_CODE
