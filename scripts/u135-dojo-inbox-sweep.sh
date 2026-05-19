#!/usr/bin/env bash
# u135-dojo-inbox-sweep.sh — daily import of any Dojo CSVs dropped into
# /home_ai/data/dojo-inbox/. Processed CSVs move to ./processed/.
#
# Until a Playwright scraper is built (U136), Jo drops CSVs from Dojo's
# "Export transactions" button into the inbox dir. This cron runs at
# 05:30 daily, scoops anything new, idempotently imports, archives.

set -euo pipefail
INBOX=/home_ai/data/dojo-inbox
ARCHIVE=$INBOX/processed
mkdir -p "$ARCHIVE"

count=0
for csv in "$INBOX"/Transactions_*.csv "$INBOX"/transactions*.csv "$INBOX"/dojo*.csv; do
  [ -f "$csv" ] || continue
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] importing $csv"
  if docker exec -i homeai-postgres bash -c "cat > /tmp/dojo-$(basename "$csv")" < "$csv" \
     && docker exec -e PG_DSN=postgresql://postgres@/homeai homeai-postgres \
        python3 /home_ai/scripts/dojo-import.py "/tmp/dojo-$(basename "$csv")"; then
    mv "$csv" "$ARCHIVE/$(date +%Y%m%d-%H%M%S)-$(basename "$csv")"
    docker exec homeai-postgres rm -f "/tmp/dojo-$(basename "$csv")" 2>/dev/null || true
    count=$((count+1))
  else
    echo "[FAIL] $csv — left in place" >&2
  fi
done

if [ "$count" -eq 0 ]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] no new CSVs to import"
fi

# Surface staleness for the backend health slug. v_dojo_freshness is a
# tiny view that other slugs read; create on first run.
docker exec -i homeai-postgres psql -U postgres -d homeai -c \
"CREATE OR REPLACE VIEW v_dojo_freshness AS
   SELECT max(transaction_date) AS last_tx,
          EXTRACT(EPOCH FROM (NOW() - max(transaction_date)::timestamp))/3600 AS hours_stale
     FROM dojo_transactions;" >/dev/null 2>&1 || true
