#!/usr/bin/env bash
# u87-audit-superuser-usage.sh — find every script that connects as postgres
# superuser and recommend a less-privileged role per script intent.
# Read-only. Output: audits/<date>-superuser-audit.md

set -euo pipefail
OUT=/home_ai/audits/$(date +%Y-%m-%d)-superuser-audit.md

{
echo "# Superuser-bypass audit"
echo ""
echo "Generated $(date -Iseconds). Read-only."
echo ""
echo "Scripts in /home_ai/scripts/ and /home_ai/services/ that connect as"
echo "\`postgres\` superuser bypass RLS by default. Each is categorised:"
echo ""
echo "- \`ddl-needed\` — runs migrations / CREATE / ALTER. Keep on superuser."
echo "- \`should-be-pipeline\` — DML only. Migrate to \`homeai_pipeline\` + SET LOCAL guards."
echo "- \`should-be-readonly\` — SELECT only. Migrate to \`homeai_readonly\`."
echo ""
echo "## Script-by-script"
echo ""
echo "| file | line | category | rationale |"
echo "|---|---|---|---|"

grep -rEn '(psql -U postgres|docker exec [^|]* homeai-postgres .*-U postgres)' \
    /home_ai/scripts/ /home_ai/services/build-dashboard/ 2>/dev/null > /tmp/su-callsites.tsv
total=$(wc -l < /tmp/su-callsites.tsv)
ddl=0; pipeline=0; readonly=0; unknown=0

while IFS=':' read -r file lineno match; do
    rel=$(realpath --relative-to=/home_ai "$file" 2>/dev/null || echo "$file")
    body=$(sed -n "$lineno,$((lineno+15))p" "$file" 2>/dev/null)
    if echo "$body" | grep -qiE 'CREATE TABLE|ALTER TABLE|CREATE INDEX|DROP TABLE|CREATE EXTENSION|CREATE POLICY|GRANT |migration|CREATE OR REPLACE'; then
        cat="ddl-needed"; ddl=$((ddl+1))
    elif echo "$body" | grep -qiE 'INSERT INTO|UPDATE |DELETE FROM|UPSERT'; then
        cat="should-be-pipeline"; pipeline=$((pipeline+1))
    elif echo "$body" | grep -qiE 'SELECT|count\(|FROM ';then
        cat="should-be-readonly"; readonly=$((readonly+1))
    else
        cat="unknown"; unknown=$((unknown+1))
    fi
    printf "| %s | %s | %s | (auto) |\n" "$rel" "$lineno" "$cat"
done < /tmp/su-callsites.tsv

echo ""
echo "## Summary"
echo ""
echo "- Total \`psql -U postgres\` callsites: $total"
echo "- ddl-needed (keep superuser): $ddl"
echo "- should-be-pipeline (migrate): $pipeline"
echo "- should-be-readonly (migrate): $readonly"
echo "- unknown (manual review): $unknown"
} > "$OUT"
echo "✓ wrote $OUT"
