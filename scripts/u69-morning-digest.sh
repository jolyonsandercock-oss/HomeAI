#!/usr/bin/env bash
#
# u69-morning-digest.sh — single 08:30 Telegram exception digest per
# SPEC §4b.7. Terse, actionable. NO message if zero exceptions in
# window (silence = success signal, per spec).

set -euo pipefail

# Pull severity/kind counts + a sample summary line for the prior-day window.
cat > /tmp/u69-digest-query.sql <<'SQL'
\pset format unaligned
\pset tuples_only on
\set ON_ERROR_STOP on
SELECT set_config('app.current_entity','all',false);
SELECT set_config('app.current_realm','owner',false);

WITH window_excs AS (
  SELECT kind, severity, summary, raised_at
    FROM mart.exceptions
   WHERE status = 'open'
     AND severity IN ('high','medium','critical')
     AND raised_at >= (CURRENT_DATE - INTERVAL '1 day' + TIME '00:00') AT TIME ZONE 'Europe/London'
     AND raised_at <  (CURRENT_DATE + TIME '06:30') AT TIME ZONE 'Europe/London'
)
SELECT kind, severity, COUNT(*) AS n, MAX(summary) AS sample
  FROM window_excs GROUP BY 1, 2 ORDER BY 1, 2;
SQL

docker cp /tmp/u69-digest-query.sql homeai-postgres:/tmp/u69-digest-query.sql >/dev/null
COUNTS=$(docker exec homeai-postgres psql -U postgres -d homeai -f /tmp/u69-digest-query.sql 2>/dev/null | grep -v '^$' || true)

if [[ -z "$COUNTS" ]]; then
    echo "[u69-digest] no high/medium exceptions in window — silent (per spec)."
    exit 0
fi

# Build the message.
MSG_FILE=$(mktemp)
{
    echo "<b>Yesterday's exceptions — $(date '+%Y-%m-%d')</b>"
    echo ""

    section() {
        local title="$1" ; local kind_pattern="$2"
        local rows
        rows=$(echo "$COUNTS" | awk -F'|' -v p="$kind_pattern" '$1 ~ p {print}')
        if [[ -n "$rows" ]]; then
            echo "<b>${title}:</b>"
            echo "$rows" | while IFS='|' read -r kind sev n sample; do
                kind=$(echo "$kind" | tr -d ' ')
                n=$(echo "$n" | tr -d ' ')
                sev_icon=$([[ "$sev" =~ critical|high ]] && echo "🚨" || echo "•")
                echo "${sev_icon} ${n}× ${kind#l[0-9]_}: ${sample}"
            done
            echo ""
        fi
    }

    section "L1 mismatches"    "^l1_"
    section "L2 fraud signals" "^l2_(phantom|card_no|pos_no|amount_mismatch|unlinked)"
    section "L2 surveillance"  "^l2_(outsized|elevated)"
    section "L3 settlements"   "^l3_"
    section "Operator patterns" "^(cash_under|refund_spike|comp_drift|late_night|open_tabs)"
} > "$MSG_FILE"

if [[ $(wc -c < "$MSG_FILE") -lt 50 ]]; then
    echo "[u69-digest] message empty after filter — silent."
    rm -f "$MSG_FILE"
    exit 0
fi

MSG=$(python3 -c "
import sys
print(open('${MSG_FILE}').read()[:4000].replace(chr(10), '%0A'))
")
rm -f "$MSG_FILE"

bash /home_ai/.claude/scripts/notify-telegram.sh "$MSG" "u69-morning-digest" >/dev/null
echo "[u69-digest] sent."
