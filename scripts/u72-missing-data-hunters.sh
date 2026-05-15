#!/usr/bin/env bash
# u72-missing-data-hunters.sh — invoke the missing-data hunter suite + the
# ghost-shift detector. Designed for a once-daily cron entry (~ 6:00 local).
#
# Output goes to stdout so cron logs reflect what was raised.

set -uo pipefail

docker exec homeai-postgres psql -U postgres -d homeai -At -c "
SELECT set_config('app.current_entity','all',false);
SELECT home_ai.set_realm('work');

SELECT 'ghost_shift_day=' || mart.run_ghost_shift_detect(14);
SELECT kind || '=' || raised FROM mart.run_missing_data_hunters();
"
