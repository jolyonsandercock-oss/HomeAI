#!/usr/bin/env bash
# u86-audit-bank-coverage.sh — per-account monthly bank-tx coverage map.
# Read-only. Output: audits/<date>-bank-coverage.md

set -euo pipefail
OUT=/home_ai/audits/$(date +%Y-%m-%d)-bank-coverage.md
mkdir -p $(dirname "$OUT")

docker exec -i homeai-postgres psql -U postgres -d homeai -At -F'|' -v ON_ERROR_STOP=1 -q <<'SQL' | grep -v '^$\|^SET$' > /tmp/bankcov.tsv
SET app.current_entity='all';
WITH bounds AS (
    SELECT bank_account_id,
           date_trunc('month', min(transaction_date))::date AS first_m,
           date_trunc('month', max(transaction_date))::date AS last_m,
           count(*) AS total_tx,
           max(transaction_date) AS latest
      FROM bank_transactions GROUP BY 1
)
SELECT
    a.id, a.entity_id, a.account_name, a.bank_name,
    coalesce(b.total_tx::text, '0'),
    coalesce(b.first_m::text, '—'),
    coalesce(b.last_m::text, '—'),
    coalesce(b.latest::text, 'NEVER')
  FROM bank_accounts a
  LEFT JOIN bounds b ON b.bank_account_id = a.id
 ORDER BY a.entity_id, a.id;
SQL

{
echo "# Bank-data coverage audit"
echo ""
echo "Generated $(date -Iseconds). Read-only."
echo ""
echo "| acct # | entity | account | bank | total tx | first month | last month | latest | flag |"
echo "|--------|--------|---------|------|----------|-------------|------------|--------|------|"
while IFS='|' read -r id ent name bank total firstm lastm latest; do
    flag=""
    [[ "$total" == "0" ]] && flag="🔴 zero-ever"
    if [[ -n "$latest" && "$latest" != "NEVER" ]]; then
        days_stale=$(( ($(date +%s) - $(date -d "$latest" +%s 2>/dev/null || echo 0)) / 86400 ))
        if (( days_stale > 30 )); then flag="🟡 ${days_stale}d stale"; fi
    fi
    printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n" \
        "$id" "$ent" "$name" "$bank" "$total" "$firstm" "$lastm" "$latest" "$flag"
done < /tmp/bankcov.tsv

echo ""
echo "## Summary"
echo ""
zero=$(awk -F'|' '$5=="0"' /tmp/bankcov.tsv | wc -l)
total=$(wc -l < /tmp/bankcov.tsv)
echo "- Total bank accounts: $total"
echo "- Accounts with zero transactions: $zero"
echo ""
} > "$OUT"
echo "✓ wrote $OUT (kept /tmp/bankcov.tsv for inspection)"
