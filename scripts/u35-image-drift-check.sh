#!/bin/bash
# /home_ai/scripts/u35-image-drift-check.sh
#
# Monthly cron: alerts if any pinned image in docker-compose.yml is more than
# 6 months behind upstream's latest tag, or older than 18 months in absolute
# terms (treating that as "definitely time to consider an update").
#
# Best-effort — failures (registry unreachable, rate limits) are logged but
# don't block.
#
# Output: writes a summary to /home_ai/logs/u35-image-drift.log; if any image
# is flagged, also Telegram-alerts via notify-telegram.sh.

set -uo pipefail
LOG=/home_ai/logs/u35-image-drift.log
{
  echo
  echo "=== $(date -Iseconds) image drift check ==="
} >> "$LOG"

# Extract image lines: postgres:16.13, n8nio/n8n:2.18.5, etc.
mapfile -t IMAGES < <(grep -oE 'image: [^ ]+' /home_ai/docker-compose.yml | awk '{print $2}' | grep -v ':[a-z]*$' | sort -u)

FLAGGED=()

for img in "${IMAGES[@]}"; do
  repo="${img%:*}"
  tag="${img##*:}"
  # Skip locally-built images (no repo path)
  if [[ "$repo" =~ ^homeai- ]]; then continue; fi

  # Probe Docker Hub for tags. Best-effort, 5s timeout.
  api_repo="$repo"
  [[ "$repo" != */* ]] && api_repo="library/$repo"
  url="https://hub.docker.com/v2/repositories/$api_repo/tags/$tag"
  resp=$(curl -sS --max-time 5 "$url" 2>/dev/null || echo "")
  if [[ -z "$resp" ]] || echo "$resp" | grep -q '"message"'; then
    echo "  ? $img — couldn't check (registry response empty/error)" >> "$LOG"
    continue
  fi
  last_updated=$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('last_updated','') or '')" 2>/dev/null)
  if [[ -z "$last_updated" ]]; then
    echo "  ? $img — no last_updated field" >> "$LOG"
    continue
  fi
  # Convert to epoch
  pin_ts=$(date -d "$last_updated" +%s 2>/dev/null || echo 0)
  now_ts=$(date +%s)
  age_days=$(( (now_ts - pin_ts) / 86400 ))

  if (( age_days > 540 )); then
    echo "  ⚠ $img — $age_days days old (>18mo)" >> "$LOG"
    FLAGGED+=("$img ($age_days days)")
  elif (( age_days > 180 )); then
    echo "  ! $img — $age_days days old (>6mo)" >> "$LOG"
    FLAGGED+=("$img ($age_days days)")
  else
    echo "  ✓ $img — $age_days days" >> "$LOG"
  fi
done

echo "  $(date -Iseconds) flagged=${#FLAGGED[@]}/${#IMAGES[@]}" >> "$LOG"

if (( ${#FLAGGED[@]} > 0 )); then
  MSG=$'📦 <b>Image drift</b> — pinned images ≥6mo old:\n'
  for f in "${FLAGGED[@]}"; do
    MSG+="  • $f\n"
  done
  MSG+=$'\nFull log: /home_ai/logs/u35-image-drift.log'
  bash /home_ai/.claude/scripts/notify-telegram.sh "$MSG" "image-drift" >/dev/null 2>&1 || true
fi

exit 0
