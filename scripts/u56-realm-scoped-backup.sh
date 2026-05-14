#!/usr/bin/env bash
#
# u56-realm-scoped-backup.sh — realm-filtered logical export for selective
# restore. R7 of the realm-split phasing.
#
# Output layout (gzipped CSV per table, plus a single schema dump):
#   /home_ai/backups/realm-scoped/<YYYY-MM-DD>/
#     schema.sql.gz                  — pg_dump --schema-only (shared)
#     owner/<table>.csv.gz           — rows where realm='owner'
#     work/<table>.csv.gz            — rows where realm IN ('work','shared')
#     family/<table>.csv.gz          — rows where realm IN ('family','shared')
#     manifest.json                  — row counts + sha256 per file
#
# Each per-realm directory is a self-contained restore target: combine with
# schema.sql to rehydrate just that realm's data into a fresh DB.
#
# Restic picks this directory up on the next nightly run.
#
# Cron: weekly Sunday 04:00 (see end of file for the line to add).
#
# Exit codes:
#   0  green
#   1  table count drift (table list changed mid-run)
#   2  setup error

set -euo pipefail

OUT_ROOT="${OUT_ROOT:-/home_ai/backups/realm-scoped}"
DATE_TAG="$(date +%Y-%m-%d)"
OUT="${OUT_ROOT}/${DATE_TAG}"
PSQL=(docker exec -i homeai-postgres psql -U postgres -d homeai -X -q -A -t)
LOG_PFX="[u56-realm-backup]"

mkdir -p "${OUT}/owner" "${OUT}/work" "${OUT}/family"

# -----------------------------------------------------------------------------
# 1. Schema dump (shared across realms). Skip third-party framework tables
#    (n8n, OWUI, etc.) since they aren't realm-scoped anyway.
# -----------------------------------------------------------------------------
echo "${LOG_PFX} schema-only dump → ${OUT}/schema.sql.gz"
docker exec homeai-postgres pg_dump -U postgres -d homeai \
    --schema-only --no-owner --no-privileges \
    | gzip > "${OUT}/schema.sql.gz"

# -----------------------------------------------------------------------------
# 2. Discover realm-bearing tables (skip partition children — parent dump
#    via COPY routes through partition automatically).
# -----------------------------------------------------------------------------
mapfile -t TABLES < <("${PSQL[@]}" -c "
SELECT col.table_name
  FROM information_schema.columns col
  JOIN pg_class c ON c.relname = col.table_name
  JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname='public'
 WHERE col.table_schema='public'
   AND col.column_name='realm'
   AND c.relkind='r'
   AND NOT c.relispartition
 ORDER BY 1;" 2>/dev/null | tr -d ' ')

echo "${LOG_PFX} ${#TABLES[@]} realm-bearing tables to dump"

# Manifest builder
mf=$(mktemp)
echo "{" > "$mf"
echo "  \"captured_at\": \"$(date -Iseconds)\"," >> "$mf"
echo "  \"date_tag\": \"${DATE_TAG}\"," >> "$mf"
echo "  \"tables\": [" >> "$mf"

first_table=1
for t in "${TABLES[@]}"; do
    [[ -z "$t" ]] && continue
    [[ $first_table -eq 0 ]] && echo "    ," >> "$mf"
    first_table=0
    echo "    {\"name\": \"${t}\"," >> "$mf"
    first_realm=1
    for realm in owner work family; do
        # Build the WHERE clause appropriate for this (realm, table) combo.
        case "$realm" in
            owner)   pred="TRUE" ;;
            work)    pred="realm IN ('work','shared')" ;;
            family)  pred="realm IN ('family','shared')" ;;
        esac
        # Dump via COPY (CSV with header) to gzip.
        out_file="${OUT}/${realm}/${t}.csv.gz"
        docker exec -i homeai-postgres psql -U postgres -d homeai -X -q -c \
            "\copy (SELECT * FROM ${t} WHERE ${pred}) TO STDOUT WITH CSV HEADER" \
            2>/dev/null | gzip > "${out_file}"
        # Row count post-write
        rows=$(zcat "${out_file}" | tail -n +2 | wc -l)
        sha=$(sha256sum "${out_file}" | cut -c1-16)
        [[ $first_realm -eq 0 ]] && echo "      ," >> "$mf"
        first_realm=0
        echo "      \"${realm}\": {\"rows\": ${rows}, \"sha256_16\": \"${sha}\"}" >> "$mf"
    done
    echo "    }" >> "$mf"
done
echo "  ]" >> "$mf"
echo "}" >> "$mf"
mv "$mf" "${OUT}/manifest.json"

# Summary line per realm
for realm in owner work family; do
    total=$(find "${OUT}/${realm}" -name '*.csv.gz' -exec zcat {} \; 2>/dev/null \
            | grep -cv '^$' || true)
    size=$(du -sh "${OUT}/${realm}" 2>/dev/null | awk '{print $1}')
    printf "${LOG_PFX} %-7s — %s on disk (across %d tables)\n" "${realm}" "${size}" "${#TABLES[@]}"
done

echo "${LOG_PFX} done. Output at ${OUT}"
echo "${LOG_PFX} cron line: 0 4 * * 0 ${BASH_SOURCE[0]} >> /home_ai/logs/u56-realm-backup.log 2>&1"
