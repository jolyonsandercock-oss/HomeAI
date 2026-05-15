#!/usr/bin/env bash
# u86-audit-dead-letters.sh — bucket dead-letter / failed / rejected
# events by error class and queue retry-action proposals.
# Read-only. Output: audits/<date>-dead-letter-triage.md

set -euo pipefail
OUT=/home_ai/audits/$(date +%Y-%m-%d)-dead-letter-triage.md
mkdir -p "$(dirname "$OUT")"

docker exec -i homeai-postgres psql -U postgres -d homeai -At -F'|' -v ON_ERROR_STOP=1 -q \
  <<'SQL' | grep -v '^$\|^SET$' > /tmp/dl.tsv
SET app.current_entity='all';
SELECT
    event_type,
    coalesce(substring(error_message, 1, 40), '(no message)') AS klass,
    count(*) AS n,
    min(created_at)::date AS oldest,
    max(created_at)::date AS newest,
    substring(coalesce(error_message,''), 1, 80) AS sample
  FROM events
 WHERE status IN ('dead_letter','failed','rejected','error')
 GROUP BY event_type, klass, sample
 ORDER BY n DESC, event_type
 LIMIT 50;
SQL

{
echo "# Dead-letter triage"
echo ""
echo "Generated $(date -Iseconds). Read-only."
echo ""
echo "Top 50 buckets of failed/dead-letter events grouped by (event_type, error_class)."
echo "Action candidates: each bucket is either safe-to-replay (idempotent emit), needs-fix (root cause), or skip (one-off corruption)."
echo ""
echo "| event_type | error_class | count | oldest | newest | sample | retry_safety |"
echo "|---|---|---|---|---|---|---|"

while IFS='|' read -r etype klass n oldest newest sample; do
    [[ -z "$etype" ]] && continue
    # Retry safety heuristic
    safety="?"
    if [[ "$etype" == email.* || "$etype" == invoice.* || "$etype" == document.* ]]; then
        safety="idempotent (safe replay)"
    elif [[ "$etype" == bank.* || "$etype" == payment.* ]]; then
        safety="destructive (manual review)"
    fi
    printf "| %s | %s | %s | %s | %s | %s | %s |\n" "$etype" "$klass" "$n" "$oldest" "$newest" "$sample" "$safety"
done < /tmp/dl.tsv

echo ""
echo "## Action queue (for U88 fix-and-forget)"
echo ""
total=$(wc -l < /tmp/dl.tsv)
echo "- Total failure buckets: $total"
echo "- Idempotent → replay candidates: see rows marked 'idempotent'"
echo "- Destructive → require human review before retry"
} > "$OUT"
echo "✓ wrote $OUT"
