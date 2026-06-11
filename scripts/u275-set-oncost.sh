#!/bin/bash
# u275-set-oncost.sh — change the workforce on-cost % CONSISTENTLY.
#
# Why: the V262 trigger applies workforce.on_cost_pct only when a row is
# (re)synced. Editing static_context alone would leave all existing shifts on
# the old multiplier — a silent base-drift. This script updates the flag AND
# recomputes history together, or recomputes a date-bounded era only.
#
# Usage:
#   ./scripts/u275-set-oncost.sh 26.92                      # set global + recompute ALL
#   ./scripts/u275-set-oncost.sh 24.10 2023-06-01 2025-04-05  # recompute an era only
#                                                             # (static_context untouched —
#                                                             #  forward rate stays as-is)
# Era use-case: employer NI changed Apr-2025 (13.8%→15%, threshold cut), so the
# true multiplier pre/post differ. Anchor each era to a Workforce on-cost report
# month and apply with the date range.
set -euo pipefail
PCT="${1:?usage: u275-set-oncost.sh <pct> [from yyyy-mm-dd] [to yyyy-mm-dd]}"
FROM="${2:-}"; TO="${3:-}"

[[ "$PCT" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "bad pct '$PCT'"; exit 1; }

if [[ -n "$FROM" && -n "$TO" ]]; then
  echo "Era recompute: $FROM..$TO at ${PCT}% (static_context unchanged)"
  docker exec -i homeai-postgres psql -d homeai -U postgres -v ON_ERROR_STOP=1 <<SQL
UPDATE workforce_shifts
   SET cost_estimate = ROUND(award_cost * (1 + ${PCT}/100.0), 2)
 WHERE award_cost IS NOT NULL
   AND shift_date BETWEEN '${FROM}' AND '${TO}';
SQL
else
  echo "Global set: workforce.on_cost_pct=${PCT} + recompute ALL costed shifts"
  docker exec -i homeai-postgres psql -d homeai -U postgres -v ON_ERROR_STOP=1 <<SQL
UPDATE static_context SET value = to_jsonb(${PCT}::numeric) WHERE key='workforce.on_cost_pct';
UPDATE workforce_shifts
   SET cost_estimate = ROUND(award_cost * (1 + ${PCT}/100.0), 2)
 WHERE award_cost IS NOT NULL;
SQL
fi

docker exec -i homeai-postgres psql -d homeai -U postgres -tAc "
SELECT 'check: May-2026 on-costed = £'||round(sum(cost_estimate),2)||' (report: £44,447.24 at 26.92%)'
FROM workforce_shifts WHERE shift_date BETWEEN '2026-05-01' AND '2026-05-31' AND hours_worked IS NOT NULL AND award_cost IS NOT NULL;"
echo "done"
