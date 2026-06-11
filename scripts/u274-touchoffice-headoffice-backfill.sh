#!/bin/bash
# u274-touchoffice-headoffice-backfill.sh
#
# Backfill + self-heal the CONSOLIDATED head_office TouchOffice aggregate.
# head_office (site 0) is the authoritative revenue source — single combined
# DRINK line, no per-till contamination (malthouse/sandwich carry a phantom
# ALCOHOL split + cross-classified items that don't match the head-office
# report). Verified to the penny vs Jo's May-2026 report: £151,516.82.
#
# Date selection (v2, 2026-06-11 review fixes):
#   - 2026-01-01 → yesterday: FULL calendar — also covers days the per-site
#     scraper missed entirely (Jan-2026 outage = 30 dates with no data at all,
#     which the v1 "dates with existing malthouse rows" list could never see).
#   - pre-2026: data-driven (dates with malthouse rows) — TouchOffice
#     historical backfill is known unreliable pre-2026; don't hammer ~700
#     genuinely dead dates every run.
#   - "missing" = NO head_office department_sales rows. This also auto-retries
#     partial scrapes (e.g. 2026-05-18 logged HTTP-ok but wrote 0 dept rows;
#     this predicate caught and healed it).
#
# Resumable + idempotent (ingest upserts on site/report_date/department).
# Newest-first. ~21s/day. Safe alongside the */15 realtime scrape (its overlap
# guard is scoped to CURRENT_DATE). Cron: nightly 04:13 — no-ops when complete
# and permanently self-heals any future per-day scrape miss.
set -uo pipefail
HOST=homeai-playwright; PORT=8001

DATES=$(docker exec -i homeai-postgres psql -d homeai -U postgres -tAc "
SET app.current_entity='all';
WITH wanted AS (
  SELECT generate_series('2026-01-01'::date, current_date - 1, '1 day')::date AS d
  UNION
  SELECT DISTINCT report_date FROM touchoffice_department_sales
   WHERE site='malthouse' AND report_date < '2026-01-01'
)
SELECT w.d::text FROM wanted w
 WHERE NOT EXISTS (SELECT 1 FROM touchoffice_department_sales h
                    WHERE h.site='head_office' AND h.report_date = w.d)
 ORDER BY w.d DESC;" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')

total=$(printf '%s\n' "$DATES" | grep -c . || true)
echo "$(date -Is) [u274] head_office backfill start: $total dates to do"
[ "$total" -eq 0 ] && { echo "$(date -Is) [u274] nothing to do"; exit 0; }

i=0; fails=0
for D in $DATES; do
  i=$((i+1))
  if docker exec "$HOST" python -c "
import urllib.request, sys
try:
    urllib.request.urlopen(urllib.request.Request('http://localhost:${PORT}/ingest/touchoffice?site=head_office&date=${D}', method='POST'), timeout=300)
except Exception as e:
    print(e); sys.exit(1)
" >/dev/null 2>&1; then
    echo "$(date -Is) [u274] [$i/$total] $D ok"
  else
    fails=$((fails+1))
    echo "$(date -Is) [u274] [$i/$total] $D FAIL (will retry on next run)"
  fi
done
echo "$(date -Is) [u274] backfill pass complete ($fails failures)"
