#!/bin/bash
# scripts/metis-digest.sh — nightly Telegram digest of top-N pending proposals by £.
# Usage: metis-digest.sh [--dry-run] [N]
set -uo pipefail
source "$(dirname "$0")/metis/common.sh"

DRY=0
N=10
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    [0-9]*) N="$a" ;;
  esac
done

BODY=$(metis_psql_value "
  SET app.current_realm='owner';
  SELECT COALESCE(string_agg(
    format('• £%s  %s → %s  (%s)', to_char(impact_gbp,'FM999990'), entity_ref,
           COALESCE(action_payload->>'category', action_kind), detector), E'\n'
    ORDER BY impact_gbp DESC), '(none)')
  FROM (SELECT * FROM cognition.proposals WHERE status='pending' LIMIT $N) q;" | grep -v '^SET$')

PENDING=$(metis_psql_value "SET app.current_realm='owner'; SELECT count(*) FROM cognition.proposals WHERE status='pending';" | grep -v '^SET$')

MSG="📋 Metis proposals — top $N of $PENDING pending (approve in dashboard):
$BODY"

if [ "$DRY" = "1" ]; then
  echo "$MSG"
else
  bash /home_ai/.claude/scripts/notify-telegram.sh "$MSG" "metis" >/dev/null 2>&1 || true
  echo "metis-digest: sent ($PENDING pending)"
fi
