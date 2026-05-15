#!/usr/bin/env bash
#
# u61-backfill-orchestrator.sh — one-shot historical fill for the feeds with
# the most coverage gaps. Targets:
#   * touchoffice_malthouse + touchoffice_sandwich — re-scrape any date in the
#     window where the OTHER site has rows but this one doesn't. Strong signal
#     of a scraper miss vs a legitimate closure.
#   * workforce_shifts — request a date-range pull from Tanda for dates with
#     touchoffice sales but no shifts.
#   * dojo — Dojo had no API import for 2024-05 → 2025-12 (CSV-only), so gaps
#     before 2026-01-01 are skipped (no source to re-fetch).
#   * vendor_invoices — already at 100% within ingested range, nothing to do.
#
# Rate-limited 1 request/s per source. Logs each action to audit_log.
#
# Re-runnable. Pass DRY_RUN=1 to preview without firing scrapers.

set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
WINDOW_DAYS="${WINDOW_DAYS:-730}"

echo "U61 backfill orchestrator — DRY_RUN=$DRY_RUN window=${WINDOW_DAYS}d"

docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 -A -t <<SQL > /tmp/u61-backfill-targets.txt
SET app.current_entity = 'all';
SET app.current_realm  = 'owner';

WITH gaps AS (
    SELECT feed_name, expected_date
      FROM feed_coverage
     WHERE status = 'missing'
       AND expected_date >= CURRENT_DATE - INTERVAL '${WINDOW_DAYS} days'
       AND expected_date < CURRENT_DATE
)
-- TouchOffice: a date is a real miss if the OTHER site has data on that date.
SELECT 'touchoffice_malthouse|' || expected_date::text FROM gaps g
 WHERE feed_name = 'touchoffice_malthouse'
   AND EXISTS (SELECT 1 FROM feed_coverage f2
                WHERE f2.feed_name = 'touchoffice_sandwich'
                  AND f2.expected_date = g.expected_date
                  AND f2.status = 'ok')
UNION ALL
SELECT 'touchoffice_sandwich|' || expected_date::text FROM gaps g
 WHERE feed_name = 'touchoffice_sandwich'
   AND EXISTS (SELECT 1 FROM feed_coverage f2
                WHERE f2.feed_name = 'touchoffice_malthouse'
                  AND f2.expected_date = g.expected_date
                  AND f2.status = 'ok')
UNION ALL
-- Workforce: real miss if there were TouchOffice sales that day on either site.
SELECT 'workforce_shifts|' || expected_date::text FROM gaps g
 WHERE feed_name = 'workforce_shifts'
   AND EXISTS (SELECT 1 FROM feed_coverage f2
                WHERE f2.feed_name IN ('touchoffice_malthouse','touchoffice_sandwich')
                  AND f2.expected_date = g.expected_date
                  AND f2.status = 'ok')
ORDER BY 1;
SQL

N=$(wc -l < /tmp/u61-backfill-targets.txt)
echo "Targets: $N rows"
if [[ "$N" == "0" ]]; then
    echo "Nothing to back-fill."
    exit 0
fi

head -20 /tmp/u61-backfill-targets.txt
echo "(showing first 20 / $N total)"

if [[ "$DRY_RUN" == "1" ]]; then
    echo
    echo "DRY_RUN=1 — exiting without firing scrapers."
    exit 0
fi

# Group by feed for batch operations.
TO_MALT=$(grep '^touchoffice_malthouse|' /tmp/u61-backfill-targets.txt | cut -d'|' -f2)
TO_SAND=$(grep '^touchoffice_sandwich|'  /tmp/u61-backfill-targets.txt | cut -d'|' -f2)
WF_DAYS=$(grep '^workforce_shifts|'      /tmp/u61-backfill-targets.txt | cut -d'|' -f2)

# Helper: log a backfill_run event to audit_log
log_event() {
    docker exec -i homeai-postgres psql -U postgres -d homeai -c \
        "INSERT INTO audit_log (action, source, payload) VALUES (
            'backfill_run', 'u61-backfill-orchestrator',
            jsonb_build_object('feed', '$1', 'date', '$2', 'status', '$3')
        );" >/dev/null
}

# ── TouchOffice (Playwright) ──────────────────────────────────────────────
TO_SCRIPT="/home_ai/scripts/u27-touchoffice-scrape-date.sh"
if [[ -f "$TO_SCRIPT" ]]; then
    for d in $TO_MALT; do
        echo "touchoffice malthouse $d"
        "$TO_SCRIPT" --site malthouse --date "$d" 2>&1 | tail -2
        log_event touchoffice_malthouse "$d" "attempted"
        sleep 1
    done
    for d in $TO_SAND; do
        echo "touchoffice sandwich $d"
        "$TO_SCRIPT" --site sandwich --date "$d" 2>&1 | tail -2
        log_event touchoffice_sandwich "$d" "attempted"
        sleep 1
    done
else
    echo "NOTE: $TO_SCRIPT not present — TouchOffice backfill is a manual scrape job."
    echo "      The current u27-touchoffice-daily.sh only scrapes 'yesterday'."
    echo "      A range-scrape script is queued for U62."
fi

# ── Workforce (Tanda API) ─────────────────────────────────────────────────
WF_SCRIPT="/home_ai/scripts/u29-workforce-sync.sh"
if [[ -f "$WF_SCRIPT" && -n "$WF_DAYS" ]]; then
    # Tanda sync script takes a day count. Compute earliest gap and pull
    # everything since then in one batch (idempotent).
    earliest=$(echo "$WF_DAYS" | sort | head -1)
    today=$(date +%F)
    span=$(( ($(date -d "$today" +%s) - $(date -d "$earliest" +%s)) / 86400 ))
    echo "workforce: pulling Tanda for last $span days (earliest gap $earliest)"
    "$WF_SCRIPT" "$span" 2>&1 | tail -3
    log_event workforce_shifts "$earliest" "attempted-${span}d"
else
    echo "NOTE: $WF_SCRIPT not present or no gaps — skipping workforce backfill"
fi

echo
echo "Re-running audit to refresh status…"
/home_ai/scripts/u61-coverage-audit.sh > /dev/null
echo "Done. Check /coverage page for the updated picture."
