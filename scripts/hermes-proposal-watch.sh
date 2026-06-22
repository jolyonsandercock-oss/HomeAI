#!/usr/bin/env bash
# hermes-proposal-watch.sh — notify Jo on Telegram when Hermes drops a new
# proposal file in /home_ai/.hermes/.  Only fires once per file; tracks seen
# proposals in SEEN_FILE so restarts don't re-alert.
set -uo pipefail

PROPOSALS_DIR="/home_ai/.hermes"
SEEN_FILE="/home_ai/logs/hermes-proposal-seen.txt"
LOG="/home_ai/logs/hermes-proposal-watch.log"

touch "$SEEN_FILE"

new=()
while IFS= read -r -d '' f; do
    fname="$(basename "$f")"
    grep -qxF "$fname" "$SEEN_FILE" || new+=("$fname")
done < <(find "$PROPOSALS_DIR" -maxdepth 1 -name '*.md' ! -name '*.applied.md' -print0 2>/dev/null)

[ ${#new[@]} -eq 0 ] && exit 0

msg="📋 HERMES PROPOSAL"
[ ${#new[@]} -gt 1 ] && msg="📋 HERMES PROPOSALS (${#new[@]})"
msg+=$'\n'
for f in "${new[@]}"; do
    msg+="• $f"$'\n'
done
msg+=$'\nReview: /home_ai/.hermes/'

PATH="$HOME/.local/bin:$HOME/.hermes/bin:$PATH" hermes send -q -t telegram "$msg" 2>>"$LOG" && {
    printf '%s\n' "${new[@]}" >> "$SEEN_FILE"
    echo "$(date -Is) notified: ${new[*]}" >> "$LOG"
} || echo "$(date -Is) WARN telegram failed for: ${new[*]}" >> "$LOG"
