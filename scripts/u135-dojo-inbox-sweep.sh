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
# Leading * is required: u33-data-lane-router deposits files prefixed with the
# gmail message id (e.g. '<msgid>__Transactions_..All-locations.csv'), so a
# start-anchored glob ('Transactions_*') silently missed every routed file.
for csv in "$INBOX"/*[Tt]ransactions*.csv "$INBOX"/*dojo*.csv; do
  [ -f "$csv" ] || continue
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] importing $csv"
  # Run the importer in homeai-bot-responder (has python3 + asyncpg + PG_DSN).
  # NOTE: the postgres container has no python3 — running it there silently
  # fails with "python3 not found" (U235 fix). cp the script + CSV in.
  if docker cp /home_ai/scripts/dojo-import.py homeai-bot-responder:/tmp/dojo-import.py >/dev/null \
     && docker cp "$csv" homeai-bot-responder:/tmp/dojo-in.csv >/dev/null \
     && docker exec homeai-bot-responder python3 /tmp/dojo-import.py /tmp/dojo-in.csv; then
    mv "$csv" "$ARCHIVE/$(date +%Y%m%d-%H%M%S)-$(basename "$csv")"
    docker exec homeai-bot-responder rm -f /tmp/dojo-in.csv 2>/dev/null || true
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
