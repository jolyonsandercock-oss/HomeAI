#!/usr/bin/env bash
# u68-doc-review-nudge.sh — daily 09:30. If there are docs needing your eye,
# fire a single concise Telegram with the count + top 5 titles. Suppressed
# silently if the queue is empty OR an identical-count notice was sent in the
# last 12 hours.

set -uo pipefail

N=$(docker exec -i homeai-postgres psql -U postgres -d homeai -A -t -X -c "
    SET app.current_entity='all'; SET app.current_realm='owner';
    SELECT COUNT(*) FROM v_documents_needing_review;
" 2>/dev/null | tail -1)

if [[ -z "$N" || "$N" -eq 0 ]]; then
    echo "u68-doc-review-nudge: queue empty, nothing to send"
    exit 0
fi

# Suppress if same-count message went out in last 12h
RECENT=$(docker exec -i homeai-postgres psql -U postgres -d homeai -A -t -X -c "
    SELECT COUNT(*) FROM telegram_outbox
     WHERE source='u68-doc-review-nudge'
       AND body_preview LIKE '%${N} docs%'
       AND sent_at > now() - interval '12 hours';" 2>/dev/null | tail -1)
if [[ -n "$RECENT" && "$RECENT" -gt 0 ]]; then
    echo "u68-doc-review-nudge: identical-count notice within 12h — suppressed"
    exit 0
fi

# Build sample
SAMPLE=$(docker exec -i homeai-postgres psql -U postgres -d homeai -A -t -X -c "
    SET app.current_entity='all'; SET app.current_realm='owner';
    SELECT '• ' || LEFT(title, 70) FROM v_documents_needing_review LIMIT 5;
" 2>/dev/null)

MSG="📋 <b>${N} docs need your eye</b>%0A%0A${SAMPLE}%0A%0A→ https://jolybox.tailc27dff.ts.net/documents"
bash /home_ai/.claude/scripts/notify-telegram.sh "$(echo -e "$MSG" | sed 's/$/\\n/' | tr -d '\n' | sed 's/\\n/\n/g')" "u68-doc-review-nudge" >/dev/null

echo "u68-doc-review-nudge: notified ($N docs)"
