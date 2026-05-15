#!/usr/bin/env bash
# next-sprint-number.sh — print the next free U-number across:
#   - git log on every branch
#   - .claude/sprints/U*.md (reserved planning slots)
#   - .claude/decisions/*.md (committed decisions referencing U-numbers)
#
# Used to prevent the U79/U83 collision pattern we hit in the U86 batch.

set -euo pipefail
cd /home_ai

git_max=$(git log --all --oneline 2>/dev/null \
    | grep -oE 'U[0-9]+' \
    | sed 's/U//' \
    | sort -n | tail -1 || echo 0)

sprint_max=$(ls -1 .claude/sprints/U*.md 2>/dev/null \
    | grep -oE 'U[0-9]+' \
    | sed 's/U//' \
    | sort -n | tail -1 || echo 0)

decision_max=$(grep -hoE 'U[0-9]+' .claude/decisions/*.md 2>/dev/null \
    | sed 's/U//' \
    | sort -n | tail -1 || echo 0)

max=$(echo -e "$git_max\n$sprint_max\n$decision_max" | sort -n | tail -1)
echo "U$((max + 1))"
