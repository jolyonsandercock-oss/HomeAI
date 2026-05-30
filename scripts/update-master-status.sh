#!/bin/bash
# update-master-status.sh — append the day's commits to MASTER.md §4.
#
# Mechanical only: captures `git log` for the day and appends a dated block to
# the daily commit log. It NEVER edits the curated §1–§3 sections (append-only),
# so it's safe to run unattended. Idempotent per calendar day.
#
# The curated Completed / Next / Degraded sections are re-classified in-session
# by Claude/Jo — this script just keeps the factual commit trail current.
#
# Cron: 50 23 * * *  (end of day). Manual: ./update-master-status.sh [since]
set -uo pipefail
cd /home_ai || exit 1
MASTER=/home_ai/MASTER.md
TODAY=$(date +%F)
SINCE="${1:-$TODAY 00:00}"

MARK="### $TODAY — commits"
if grep -qF "$MARK" "$MASTER" 2>/dev/null; then
  echo "$(date -Iseconds) already logged for $TODAY"; exit 0
fi

LOG=$(git log --since="$SINCE" --no-merges --pretty=format:'- %h %s' 2>/dev/null)
if [ -z "$LOG" ]; then
  echo "$(date -Iseconds) no commits since $SINCE — nothing to append"; exit 0
fi

{ printf '\n%s\n' "$MARK"; printf '%s\n' "$LOG"; } >> "$MASTER"
echo "$(date -Iseconds) appended $(printf '%s\n' "$LOG" | wc -l) commit(s) for $TODAY"
