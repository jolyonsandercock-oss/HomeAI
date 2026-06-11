#!/bin/bash
# u274-touchoffice-headoffice-backfill.sh
#
# Backfill the CONSOLIDATED head_office TouchOffice aggregate for every date that
# has per-site data but no head_office scrape yet. head_office (site 0) is the
# authoritative revenue source — single combined DRINK line, no per-till
# contamination (the malthouse/sandwich scrapes carry a phantom ALCOHOL split +
# cross-classified items that don't match the head-office report).
#
# Resumable: re-running skips dates already covered. Newest-first so recent
# months (the ones used for labour-vs-sales) reconcile first. ~21s/day.
# Coexists with the */15 realtime scrape (that guard is scoped to CURRENT_DATE).
set -uo pipefail
HOST=homeai-playwright; PORT=8001

DATES=$(docker exec -i homeai-postgres psql -d homeai -U postgres -tAc "
SET app.current_entity='all';
SELECT DISTINCT d.report_date::text
  FROM touchoffice_department_sales d
 WHERE d.site='malthouse'
   AND NOT EXISTS (SELECT 1 FROM touchoffice_department_sales h
                    WHERE h.site='head_office' AND h.report_date = d.report_date)
 ORDER BY 1 DESC;")

total=$(printf '%s\n' "$DATES" | grep -c . || true)
echo "$(date -Is) [u274] head_office backfill start: $total dates to do"
i=0
for D in $DATES; do
  i=$((i+1))
  if docker exec "$HOST" python -c "
import urllib.request, urllib.error, sys
try:
    urllib.request.urlopen(urllib.request.Request('http://localhost:${PORT}/ingest/touchoffice?site=head_office&date=${D}', method='POST'), timeout=300)
except Exception as e:
    print(e); sys.exit(1)
" >/dev/null 2>&1; then
    echo "$(date -Is) [u274] [$i/$total] $D ok"
  else
    echo "$(date -Is) [u274] [$i/$total] $D FAIL (will retry on next run)"
  fi
done
echo "$(date -Is) [u274] backfill complete"
