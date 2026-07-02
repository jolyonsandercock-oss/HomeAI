#!/usr/bin/env bash
# u89-audit-memory.sh — verify every memory file is indexed in MEMORY.md and
# every [[wiki-link]] resolves. Read-only.
# Output: audits/<date>-memory-hygiene.md

set -euo pipefail
OUT=/home_ai/audits/$(date +%Y-%m-%d)-memory-hygiene.md

MEMDIR=/home/joly/.claude/projects/-home-joly/memory
INDEX=$MEMDIR/MEMORY.md

{
echo "# Memory hygiene audit"
echo ""
echo "Generated $(date -Iseconds). Read-only."
echo ""
if [[ ! -d "$MEMDIR" ]]; then
    echo "Memory dir not found at $MEMDIR — skipping."
    exit 0
fi

# Index entries
echo "## Files on disk"
echo ""
on_disk=$(ls "$MEMDIR"/*.md 2>/dev/null | grep -v MEMORY.md | xargs -n1 basename || true)
n_disk=$(echo "$on_disk" | wc -l)
echo "Total memory files (excl. MEMORY.md): $n_disk"
echo ""
echo '```'
echo "$on_disk"
echo '```'
echo ""

# Linked in MEMORY.md
echo "## Indexed in MEMORY.md"
echo ""
linked=$(grep -oE '\([a-z_-]+\.md\)' "$INDEX" 2>/dev/null | tr -d '()' | sort -u || true)
n_linked=$(echo "$linked" | wc -l)
echo "Total linked entries: $n_linked"
echo ""

# Unindexed (on disk but not in MEMORY.md)
echo "## Unindexed (file on disk, no MEMORY.md link)"
echo ""
unindexed=$(comm -23 <(echo "$on_disk" | sort -u) <(echo "$linked" | sort -u))
if [[ -z "$unindexed" ]]; then
    echo "(none — every file is linked)"
else
    echo '```'
    echo "$unindexed"
    echo '```'
fi
echo ""

# Dangling (in MEMORY.md but file missing)
echo "## Dangling (linked in MEMORY.md but file absent)"
echo ""
dangling=$(comm -13 <(echo "$on_disk" | sort -u) <(echo "$linked" | sort -u))
if [[ -z "$dangling" ]]; then
    echo "(none — every linked file exists)"
else
    echo '```'
    echo "$dangling"
    echo '```'
fi
echo ""

# Wiki-link refs across all memory files
echo "## Wiki-link \`[[name]]\` references"
echo ""
wiki_refs=$(grep -rhoE '\[\[[a-z_-]+\]\]' "$MEMDIR"/*.md 2>/dev/null | sort -u || true)
if [[ -n "$wiki_refs" ]]; then
    echo "All \`[[link]]\` targets seen:"
    echo ""
    while IFS= read -r ref; do
        target=$(echo "$ref" | tr -d '[]')
        if ls "$MEMDIR"/${target}.md >/dev/null 2>&1; then
            echo "- $ref → ✓ ${target}.md"
        else
            echo "- $ref → 🔴 missing file ${target}.md"
        fi
    done <<< "$wiki_refs"
else
    echo "(no wiki-style \`[[link]]\` references found)"
fi
} > "$OUT"
echo "✓ wrote $OUT"
