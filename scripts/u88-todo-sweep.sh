#!/usr/bin/env bash
# u88-todo-sweep.sh — find every TODO/FIXME/XXX/HACK marker in code and
# group by location. Read-only. Output: audits/<date>-todo-sweep.md

set -uo pipefail
OUT=/home_ai/audits/$(date +%Y-%m-%d)-todo-sweep.md

# Search code dirs; skip archives + vendor
grep -rEn --include='*.py' --include='*.sh' --include='*.sql' --include='*.html' --include='*.js' --include='*.ts' \
    'TODO|FIXME|XXX|HACK' \
    /home_ai/scripts/ /home_ai/services/build-dashboard/ /home_ai/services/bot-responder/ \
    --exclude-dir=_archive --exclude-dir=__pycache__ --exclude-dir=node_modules 2>/dev/null \
    > /tmp/todos.tsv || true

{
echo "# TODO / FIXME sweep"
echo ""
echo "Generated $(date -Iseconds). Read-only."
echo ""
echo "Every TODO/FIXME/XXX/HACK marker found in scripts/, services/build-dashboard/, services/bot-responder/."
echo "Archived dirs and \`__pycache__\` excluded."
echo ""

if [[ ! -s /tmp/todos.tsv ]]; then
    echo "## Result: ✓ no TODOs found"
else
    total=$(wc -l < /tmp/todos.tsv)
    echo "## Total: $total markers"
    echo ""
    echo "### By file"
    echo ""
    echo "| file | count | examples |"
    echo "|---|---|---|"
    cut -d: -f1 /tmp/todos.tsv | sort | uniq -c | sort -rn | while read -r n file; do
        rel=$(realpath --relative-to=/home_ai "$file" 2>/dev/null || echo "$file")
        sample=$(grep -m 2 -E 'TODO|FIXME|XXX|HACK' "$file" 2>/dev/null | head -2 | sed 's/^[[:space:]]*//' | tr '\n' '|' | sed 's/|/ \\| /')
        printf "| %s | %s | %s |\n" "$rel" "$n" "${sample:0:120}"
    done
    echo ""
    echo "### Full list (first 50)"
    echo ""
    echo '```'
    head -50 /tmp/todos.tsv | while IFS=':' read -r file lineno text; do
        rel=$(realpath --relative-to=/home_ai "$file" 2>/dev/null || echo "$file")
        echo "  $rel:$lineno  $(echo "$text" | sed 's/^[[:space:]]*//' | head -c 100)"
    done
    echo '```'
fi
} > "$OUT"
echo "✓ wrote $OUT"
