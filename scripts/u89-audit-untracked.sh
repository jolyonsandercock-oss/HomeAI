#!/usr/bin/env bash
# u89-audit-untracked.sh — find files on disk under /home_ai that aren't
# in git and classify them. Read-only.
# Output: audits/<date>-untracked-files.md

set -euo pipefail
OUT=/home_ai/audits/$(date +%Y-%m-%d)-untracked-files.md

cd /home_ai
git status --porcelain | awk '$1 ~ /^\?\?/ {print $2}' > /tmp/untracked.tsv

{
echo "# Untracked file sweep"
echo ""
echo "Generated $(date -Iseconds). Read-only."
echo ""
total=$(wc -l < /tmp/untracked.tsv)
echo "Total untracked paths: $total"
echo ""
echo "## Classification"
echo ""
echo "| path | class | suggested action |"
echo "|---|---|---|"

scripts=0; docs=0; logs=0; tmps=0; archive=0; other=0
while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    case "$path" in
        scripts/u*-*.sh|scripts/u*.py|scripts/u*.sql) class="recent-u-script"; action="\`git add\`"; scripts=$((scripts+1));;
        scripts/_archive/*) class="archive"; action="(skip — already in _archive)"; archive=$((archive+1));;
        */node_modules/*|*__pycache__*|*.pyc) class="cache"; action="add to .gitignore"; tmps=$((tmps+1));;
        *.log|*.pid|*.swp|*.tmp) class="ephemeral"; action="add to .gitignore"; logs=$((logs+1));;
        docs/*|audits/*) class="generated-doc"; action="\`git add\`"; docs=$((docs+1));;
        *.bak|*~) class="backup"; action="delete"; tmps=$((tmps+1));;
        *) class="unclassified"; action="human review"; other=$((other+1));;
    esac
    printf "| \`%s\` | %s | %s |\n" "$path" "$class" "$action"
done < /tmp/untracked.tsv

echo ""
echo "## Summary"
echo ""
echo "- Recent u-scripts (likely to add): $scripts"
echo "- Generated docs/audits (to add): $docs"
echo "- Archive (skip): $archive"
echo "- Ephemeral (gitignore): $logs"
echo "- Cache (gitignore): $tmps"
echo "- Unclassified: $other"
} > "$OUT"
echo "✓ wrote $OUT"
