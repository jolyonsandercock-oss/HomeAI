#!/usr/bin/env bash
# u86-audit-idempotency.sh — confirm idempotency_key columns are populated
# and that the convention holds (UNIQUE where required, dup-tolerated for events).
# Read-only. Output: audits/<date>-idempotency-audit.md

set -euo pipefail
OUT=/home_ai/audits/$(date +%Y-%m-%d)-idempotency-audit.md
mkdir -p "$(dirname "$OUT")"

# Tables expected to enforce UNIQUE on idempotency_key
UNIQUE_TABLES=(bank_transactions vendor_invoice_inbox dojo_transactions clover_batches till_reconciliation touchoffice_plu_sales touchoffice_department_sales)
# events deliberately allows duplicates

docker exec -i homeai-postgres psql -U postgres -d homeai -At -F'|' -v ON_ERROR_STOP=0 -q \
  <<'SQL' | grep -v '^$\|^SET$' > /tmp/idem-cols.tsv
SET app.current_entity='all';
-- Tables that have an idempotency_key column
SELECT table_schema||'.'||table_name, column_name
  FROM information_schema.columns
 WHERE column_name = 'idempotency_key'
   AND table_schema IN ('public','mart','staging')
 ORDER BY 1;
SQL

{
echo "# Idempotency-key audit"
echo ""
echo "Generated $(date -Iseconds). Read-only."
echo ""
echo "## Convention (per AGENTS.md rule 7)"
echo ""
echo "- \`events.idempotency_key\` — no UNIQUE; intentional re-emit tolerated."
echo "- Other tables — UNIQUE constraint enforced; populated on every insert."
echo ""
echo "## Per-table state"
echo ""
echo "| table | rows | null idempotency | unique-violation potential | enforced UNIQUE |"
echo "|---|---|---|---|---|"

while IFS='|' read -r tbl col; do
    [[ -z "$tbl" ]] && continue
    stats=$(docker exec homeai-postgres psql -U postgres -d homeai -At -F'|' -v ON_ERROR_STOP=0 -q </dev/null -c \
        "SET app.current_entity='all'; SELECT count(*), count(*) FILTER (WHERE \"$col\" IS NULL), count(*) - count(DISTINCT \"$col\") FROM $tbl;" 2>/dev/null | grep -v '^$\|^SET$' | head -1)
    n=$(echo "$stats" | cut -d'|' -f1)
    nulls=$(echo "$stats" | cut -d'|' -f2)
    dupes=$(echo "$stats" | cut -d'|' -f3)
    # Check if UNIQUE
    short_tbl=$(echo "$tbl" | sed 's/^public\.//')
    has_unique=$(docker exec homeai-postgres psql -U postgres -d homeai -At -v ON_ERROR_STOP=0 -q </dev/null -c \
        "SELECT count(*) FROM pg_constraint c JOIN pg_class t ON c.conrelid=t.oid JOIN pg_attribute a ON a.attrelid=t.oid AND a.attnum=ANY(c.conkey) WHERE t.relname='$short_tbl' AND a.attname='idempotency_key' AND c.contype IN ('u','p');" 2>/dev/null | grep -v '^$\|^SET$' | head -1)
    unique_flag="—"
    if [[ "$has_unique" =~ ^[1-9] ]]; then unique_flag="✓"; fi
    if [[ "$short_tbl" == "events" ]]; then unique_flag="(by design, none)"; fi

    flag=""
    if [[ "$nulls" =~ ^[1-9] ]]; then flag="🟡 nulls"; fi
    if [[ "$dupes" =~ ^[1-9] ]] && [[ "$unique_flag" == "✓" ]]; then flag="🔴 should not happen"; fi

    printf "| %s | %s | %s | %s %s | %s |\n" "$tbl" "$n" "$nulls" "$dupes" "$flag" "$unique_flag"
done < /tmp/idem-cols.tsv

echo ""
echo "## Convention violations"
echo "Any row in the table above marked 🔴 means UNIQUE was claimed but duplicates exist. None expected."
} > "$OUT"
echo "✓ wrote $OUT"
