#!/usr/bin/env bash
# u86-audit-fk-orphans.sh — find FK references pointing at non-existent rows.
# Read-only. Output: audits/<date>-fk-orphans.md

set -euo pipefail
OUT=/home_ai/audits/$(date +%Y-%m-%d)-fk-orphans.md
mkdir -p "$(dirname "$OUT")"

docker exec -i homeai-postgres psql -U postgres -d homeai -At -F'|' -v ON_ERROR_STOP=1 -q \
  <<'SQL' | grep -v '^$\|^SET$' > /tmp/fkdef.tsv
SET app.current_entity='all';
-- pg_catalog query is ~100× faster than information_schema for FK enumeration
SELECT
    cn.nspname || '.' || cl.relname  AS child,
    ca.attname                       AS fk_col,
    pn.nspname || '.' || pl.relname  AS parent,
    pa.attname                       AS pk_col,
    CASE c.confdeltype WHEN 'a' THEN 'NO ACTION' WHEN 'r' THEN 'RESTRICT'
                       WHEN 'c' THEN 'CASCADE'  WHEN 'n' THEN 'SET NULL'
                       WHEN 'd' THEN 'SET DEFAULT' END  AS delete_rule
  FROM pg_constraint c
  JOIN pg_class      cl ON c.conrelid  = cl.oid
  JOIN pg_namespace  cn ON cl.relnamespace = cn.oid
  JOIN pg_class      pl ON c.confrelid = pl.oid
  JOIN pg_namespace  pn ON pl.relnamespace = pn.oid
  JOIN pg_attribute  ca ON ca.attrelid = c.conrelid  AND ca.attnum = c.conkey[1]
  JOIN pg_attribute  pa ON pa.attrelid = c.confrelid AND pa.attnum = c.confkey[1]
 WHERE c.contype = 'f'
   AND cn.nspname NOT IN ('pg_catalog','information_schema')
 ORDER BY child, fk_col;
SQL

{
echo "# FK orphan scan"
echo ""
echo "Generated $(date -Iseconds). Read-only."
echo ""
echo "Checks every FK in the schema for child rows whose foreign key points at a non-existent parent row."
echo ""
echo "| child | fk col | parent | pk col | orphan count | delete rule |"
echo "|---|---|---|---|---|---|"

orphans_total=0
clean=0
while IFS='|' read -r child fk_col parent pk_col delete_rule; do
    [[ -z "$child" ]] && continue
    # Count orphans for this FK
    # NB: no `-i` here — would steal the outer loop's stdin.
    count=$(docker exec homeai-postgres psql -U postgres -d homeai -At -v ON_ERROR_STOP=0 -q -c \
        "SELECT count(*) FROM $child c WHERE c.\"$fk_col\" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM $parent p WHERE p.\"$pk_col\" = c.\"$fk_col\");" </dev/null 2>/dev/null | grep -v '^$\|^SET$' | head -1 || echo "?")
    flag=""
    if [[ "$count" =~ ^[0-9]+$ ]]; then
        if (( count > 0 )); then
            flag="🔴"
            orphans_total=$((orphans_total + count))
        else
            clean=$((clean + 1))
        fi
    fi
    printf "| %s | %s | %s | %s | %s %s | %s |\n" \
        "$child" "$fk_col" "$parent" "$pk_col" "$count" "$flag" "$delete_rule"
done < /tmp/fkdef.tsv

echo ""
echo "## Summary"
echo ""
total_fks=$(wc -l < /tmp/fkdef.tsv)
echo "- Total FK constraints checked: $total_fks"
echo "- Clean (0 orphans): $clean"
echo "- Total orphaned rows across all FKs: $orphans_total"
} > "$OUT"
echo "✓ wrote $OUT"
