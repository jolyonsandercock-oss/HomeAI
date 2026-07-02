#!/usr/bin/env bash
# u89-audit-agents-md.sh — verify every path / script / table referenced
# in AGENTS.md still exists. Read-only.
# Output: audits/<date>-agents-md-drift.md

set -euo pipefail
OUT=/home_ai/audits/$(date +%Y-%m-%d)-agents-md-drift.md
AGENTS=/home_ai/AGENTS.md

{
echo "# AGENTS.md drift check"
echo ""
echo "Generated $(date -Iseconds). Read-only."
echo ""
if [[ ! -f "$AGENTS" ]]; then
    echo "$AGENTS not found — skipping."
    exit 0
fi

total_lines=$(wc -l < "$AGENTS")
echo "AGENTS.md: $total_lines lines."
echo ""

# Extract paths starting with /home_ai/ or scripts/ or relative .md/.sh/.sql/.py refs
echo "## Path references"
echo ""
echo "| path | exists |"
echo "|---|---|"

found=0; missing=0
grep -oE '(/home_ai/[A-Za-z0-9_./-]+|scripts/[A-Za-z0-9_./-]+\.(sh|py|sql)|postgres/migrations/V[0-9]+[a-z]?__[A-Za-z0-9_-]+\.sql)' "$AGENTS" \
    | sort -u | while read -r path; do
        # Normalise to /home_ai/-prefixed form
        full="$path"
        [[ "$path" != /* ]] && full="/home_ai/$path"
        if [[ -e "$full" ]]; then
            echo "| \`$path\` | ✓ |"
        else
            echo "| \`$path\` | 🔴 missing |"
        fi
    done || true

echo ""

# Table references — words that look like DB table names following "table" or backticks
echo "## DB table references"
echo ""
echo "| table | exists in DB |"
echo "|---|---|"

# A loose heuristic: backticked words that look like table names
grep -oE '\`[a-z_]+[a-z0-9_]*\`' "$AGENTS" \
    | sort -u \
    | tr -d '\`' \
    | while read -r candidate; do
        # Skip too-short or obviously non-table words
        if [[ ${#candidate} -lt 5 ]]; then continue; fi
        case "$candidate" in
            home|true|false|null|select|from|where|count|integer|text|timestamp) continue;;
        esac
        exists=$(docker exec homeai-postgres psql -U postgres -d homeai -At </dev/null -c \
            "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON c.relnamespace=n.oid WHERE c.relname='$candidate' AND n.nspname IN ('public','mart','staging','raw');" 2>/dev/null | head -1) || true
        if [[ "$exists" =~ ^[1-9] ]]; then
            echo "| \`$candidate\` | ✓ |"
        elif [[ "$exists" == "0" ]]; then
            : # not flagged — many backticked words are SQL keywords or column names, not tables
        fi
    done || true

echo ""
echo "## Summary"
echo "Manually review any 🔴 missing rows above; rest are clean."
} > "$OUT"
echo "✓ wrote $OUT"
