#!/bin/bash
# /home_ai/scripts/u33-touchoffice-realtime.sh
#
# */10 TouchOffice scrape for TODAY across both sites. Wraps the existing
# u27-touchoffice-daily.sh with:
#   - "today" semantics (vs the daily 03:00 job that scrapes "yesterday")
#   - skip-if-overlap guard: abort if MAX(scraped_at) < 8 min ago
#
# Cron: */10 * * * *. The 03:00 daily job remains for the previous-day pass.

set -uo pipefail
TODAY=$(date '+%Y-%m-%d')

# ── Overlap guard ────────────────────────────────────────────
# If any scrape finished within the last 8 minutes, bail. */10 cadence with
# a 2-3 min runtime per pass means we never naturally re-enter, but a long
# stall could queue another invocation; the guard prevents pile-up.
LAST_AGE_SEC=$(docker exec homeai-postgres psql -U postgres -d homeai -tA -c \
  "SELECT COALESCE(EXTRACT(EPOCH FROM (now() - MAX(scraped_at)))::int, 99999) FROM touchoffice_scrapes WHERE scraped_at >= now() - interval '1 hour';" 2>/dev/null || echo 99999)

if [[ "$LAST_AGE_SEC" =~ ^[0-9]+$ ]] && (( LAST_AGE_SEC < 480 )); then
  echo "$(date -Iseconds) skip — last scrape ${LAST_AGE_SEC}s ago (< 480s)"
  exit 0
fi

exec /home_ai/scripts/u27-touchoffice-daily.sh "$TODAY"
