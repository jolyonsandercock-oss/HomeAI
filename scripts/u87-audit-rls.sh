#!/usr/bin/env bash
# u87-audit-rls.sh — RLS policy coverage map.
# Every RLS-enabled table should have entity_isolation (PERMISSIVE) +
# realm_isolation (RESTRICTIVE). Tables with entity_id or realm columns
# that are NOT RLS-enabled are flagged as suspicious.
# Read-only. Output: audits/<date>-rls-coverage.md

set -euo pipefail
OUT=/home_ai/audits/$(date +%Y-%m-%d)-rls-coverage.md

docker exec -i homeai-postgres psql -U postgres -d homeai -At -F'|' -v ON_ERROR_STOP=1 -q \
  <<'SQL' | grep -v '^$\|^SET$' > /tmp/rls-state.tsv
SET app.current_entity='all';
WITH rls_tables AS (
    SELECT n.nspname || '.' || c.relname AS tbl, c.relrowsecurity AS rls_enabled, c.relforcerowsecurity AS rls_forced
      FROM pg_class c JOIN pg_namespace n ON c.relnamespace=n.oid
     WHERE c.relkind = 'r' AND n.nspname IN ('public','mart','staging','raw')
),
policies AS (
    SELECT n.nspname || '.' || c.relname AS tbl,
           string_agg(p.polname || '(' || (CASE p.polpermissive WHEN true THEN 'P' ELSE 'R' END) || ')', ',') AS pols
      FROM pg_policy p
      JOIN pg_class c ON p.polrelid=c.oid
      JOIN pg_namespace n ON c.relnamespace=n.oid
     GROUP BY 1
),
columns AS (
    SELECT n.nspname || '.' || c.relname AS tbl,
           bool_or(a.attname='entity_id') AS has_entity_id,
           bool_or(a.attname='realm') AS has_realm
      FROM pg_attribute a JOIN pg_class c ON a.attrelid=c.oid JOIN pg_namespace n ON c.relnamespace=n.oid
     WHERE c.relkind='r' AND a.attnum>0 AND n.nspname IN ('public','mart','staging','raw')
     GROUP BY 1
)
SELECT r.tbl, r.rls_enabled, r.rls_forced,
       coalesce(p.pols, '(none)') AS policies,
       coalesce(co.has_entity_id, false) AS has_entity,
       coalesce(co.has_realm, false) AS has_realm
  FROM rls_tables r
  LEFT JOIN policies p ON p.tbl = r.tbl
  LEFT JOIN columns co ON co.tbl = r.tbl
 ORDER BY r.tbl;
SQL

{
echo "# RLS coverage audit"
echo ""
echo "Generated $(date -Iseconds). Read-only."
echo ""
echo "Required policies per RLS-enabled table:"
echo "- \`entity_isolation\` (PERMISSIVE) — filters by app.current_entity"
echo "- \`realm_isolation\` (RESTRICTIVE) — filters by app.current_realm"
echo ""
echo "## Table-by-table"
echo ""
echo "| table | RLS on | forced | policies | has entity_id | has realm | flag |"
echo "|---|---|---|---|---|---|---|"

rls_off_with_columns=0
rls_on_missing_policy=0
rls_clean=0
while IFS='|' read -r tbl rls forced pols has_ent has_realm; do
    [[ -z "$tbl" ]] && continue
    flag=""
    if [[ "$rls" == "f" ]] && [[ "$has_ent" == "t" || "$has_realm" == "t" ]]; then
        flag="🟡 has entity/realm but RLS off"
        rls_off_with_columns=$((rls_off_with_columns + 1))
    fi
    if [[ "$rls" == "t" ]]; then
        # Must have at least entity_isolation OR realm_isolation
        if [[ "$pols" == "(none)" ]] || ! echo "$pols" | grep -qE 'entity_isolation|realm_isolation'; then
            flag="🔴 RLS on but no isolation policy"
            rls_on_missing_policy=$((rls_on_missing_policy + 1))
        else
            rls_clean=$((rls_clean + 1))
        fi
    fi
    printf "| %s | %s | %s | %s | %s | %s | %s |\n" \
        "$tbl" "$rls" "$forced" "$pols" "$has_ent" "$has_realm" "$flag"
done < /tmp/rls-state.tsv

total=$(wc -l < /tmp/rls-state.tsv)
echo ""
echo "## Summary"
echo ""
echo "- Total tables: $total"
echo "- RLS-on with isolation policies: $rls_clean"
echo "- RLS-off with entity/realm columns (suspicious): $rls_off_with_columns"
echo "- RLS-on missing isolation policies (broken): $rls_on_missing_policy"
} > "$OUT"
echo "✓ wrote $OUT"
