#!/usr/bin/env bash
# u86-audit-hunters-rerun.sh — re-run missing-data hunters + ghost shift
# detector and summarise findings.
# Read-write (the hunters insert mart.exceptions on detect, but idempotent).
# Output: audits/<date>-missing-data-summary.md

set -euo pipefail
OUT=/home_ai/audits/$(date +%Y-%m-%d)-missing-data-summary.md
mkdir -p "$(dirname "$OUT")"

# Invoke both hunters
HUNT_OUT=$(bash /home_ai/scripts/u72-missing-data-hunters.sh 2>&1 || true)

# Pull exception counts post-run
COUNTS=$(docker exec -i homeai-postgres psql -U postgres -d homeai -At -F'|' -v ON_ERROR_STOP=0 -q -c \
"SET app.current_entity='all';
 SELECT kind, count(*) FILTER (WHERE status='open') AS open, count(*) AS total, max(raised_at)::date AS latest
   FROM mart.exceptions
  WHERE kind IN ('to_scrape_gap','dojo_settlement_gap','till_recon_missing','ghost_shift_day')
  GROUP BY kind ORDER BY kind;" 2>/dev/null | grep -v '^$\|^SET$' || true)

# Confirm cron entries
CRON=$(crontab -l 2>/dev/null | grep -E 'u72-missing-data-hunters|u75-pipeline-smoke|u67-recon-l1' || echo "(no relevant cron found)")

{
echo "# Missing-data hunter summary"
echo ""
echo "Generated $(date -Iseconds)."
echo ""
echo "## Latest hunter run"
echo ""
echo '```'
echo "$HUNT_OUT"
echo '```'
echo ""
echo "## Exception state per hunter kind"
echo ""
echo "| kind | open | total seen | latest |"
echo "|---|---|---|---|"
while IFS='|' read -r kind open total latest; do
    [[ -z "$kind" ]] && continue
    echo "| $kind | $open | $total | $latest |"
done <<< "$COUNTS"
echo ""
echo "## Cron"
echo ""
echo '```'
echo "$CRON"
echo '```'
} > "$OUT"
echo "✓ wrote $OUT"
