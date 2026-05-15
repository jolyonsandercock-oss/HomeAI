#!/usr/bin/env bash
# u89-regen-status.sh — regenerate STATUS.md from recent git activity,
# audit index, and pending instructions. Idempotent.
# Output: STATUS.md (overwrites)

set -uo pipefail
cd /home_ai
OUT=STATUS.md

# Pending bot_instructions
PENDING=$(docker exec homeai-postgres psql -U postgres -d homeai -At -c \
    "SELECT count(*) FROM bot_instructions WHERE status='pending';" 2>/dev/null | grep -v '^$\|^SET$' | head -1)
# Open mart.exceptions critical
CRITICAL=$(docker exec homeai-postgres psql -U postgres -d homeai -At -c \
    "SELECT count(*) FROM mart.exceptions WHERE severity='critical' AND status='open';" 2>/dev/null | grep -v '^$\|^SET$' | head -1)
# Recent commits (last 20)
COMMITS=$(git log --oneline -20)
# Audit index
AUDIT_TOC=""
if [[ -f audits/INDEX.md ]]; then
    AUDIT_TOC=$(grep -E '^## 20' audits/INDEX.md | head -5)
fi

{
echo "# STATUS"
echo ""
echo "_generated: $(date -Iseconds)_"
echo "_by: scripts/u89-regen-status.sh_"
echo ""
echo "## Current branch"
echo ""
echo "\`$(git branch --show-current)\` at \`$(git rev-parse --short HEAD)\`"
echo ""
echo "## Recent commits (last 20)"
echo ""
echo '```'
echo "$COMMITS"
echo '```'
echo ""
echo "## Open work signals"
echo ""
echo "- Pending bot_instructions: $PENDING"
echo "- Open CRITICAL exceptions: $CRITICAL"
echo "- Working-tree state: $(git status --porcelain | wc -l) files modified/untracked"
echo ""
echo "## Audit log recent entries"
echo ""
echo "$AUDIT_TOC"
echo ""
echo "## Active sprint plans"
echo ""
for f in .claude/sprints/U[8-9][0-9]-*.md .claude/sprints/U9[0-9]-*.md; do
    [[ -f "$f" ]] || continue
    title=$(head -1 "$f" | sed 's/^# *//')
    echo "- \`$(basename "$f")\` — $title"
done
echo ""
echo "_Re-run: \`scripts/u89-regen-status.sh\`_"
} > "$OUT"
echo "✓ wrote $OUT"
