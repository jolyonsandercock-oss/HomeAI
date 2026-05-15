#!/usr/bin/env bash
# u62-doc-alerts.sh — daily 09:00. Telegram alert if any document is expired,
# expiring within 30d, or has a review_date due. Quiet if nothing to flag.

set -euo pipefail

OUT=$(docker exec -i homeai-postgres psql -U postgres -d homeai -A -t <<'SQL'
SET app.current_entity='all'; SET app.current_realm='owner';
SELECT
    state || E'\t' || COALESCE(linked_table,'-') || E'\t' ||
    COALESCE(soonest_date::text,'-') || E'\t' || title
  FROM v_documents_expiry_due
 ORDER BY soonest_date NULLS LAST
 LIMIT 25;
SQL
)

if [[ -z "$OUT" ]]; then
    echo "u62-doc-alerts: nothing to flag"
    exit 0
fi

n=$(echo "$OUT" | wc -l)
msg=$'📄 Document review queue ('"$n"$' item'$([[ "$n" -eq 1 ]] && echo "" || echo "s")$'):\n'
while IFS=$'\t' read -r state linked date title; do
    icon=$(case "$state" in
        expired) echo "🔴";;
        expiring_soon) echo "🟡";;
        review_due) echo "🔵";;
        *) echo "•";;
    esac)
    msg+="$icon $title ($state, $date, $linked)"$'\n'
done <<< "$OUT"

# Push via existing telegram_outbox path (consumed by u29-heartbeat cron path)
docker exec -i homeai-postgres psql -U postgres -d homeai <<SQL >/dev/null
SET app.current_entity='all'; SET app.current_realm='owner';
INSERT INTO telegram_outbox (channel, severity, body, source)
VALUES ('alerts', 'info', \$\$$msg\$\$, 'u62-doc-alerts');
SQL
echo "u62-doc-alerts: queued $n alerts"
