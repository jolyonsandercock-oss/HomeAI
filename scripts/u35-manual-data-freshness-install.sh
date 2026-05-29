#!/bin/bash
# Install u35-manual-data-freshness.sh: tighten perms, add a root crontab
# entry (08:00 daily), and fire a test message.
#
# Run as root.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "✗ must run as root"
  exit 1
fi

SCRIPT=/home_ai/scripts/u35-manual-data-freshness.sh
LOG=/home_ai/logs/u35-manual-data-freshness.log
CRON_LINE="0 8 * * * $SCRIPT >> $LOG 2>&1"
CRON_TAG="# u35-manual-data-freshness"

[[ -x "$SCRIPT" || -r "$SCRIPT" ]] || { echo "✗ $SCRIPT missing"; exit 1; }

echo "→ tightening script perms"
chown root:root "$SCRIPT"
chmod 0700 "$SCRIPT"

echo "→ ensuring log dir + file exist"
mkdir -p "$(dirname "$LOG")"
touch "$LOG"
chown root:root "$LOG"
chmod 0640 "$LOG"

echo "→ installing root crontab entry"
TMP=$(mktemp)
crontab -l 2>/dev/null | grep -v 'u35-manual-data-freshness' > "$TMP" || true
{
  cat "$TMP"
  printf '\n%s\n%s\n' "$CRON_TAG" "$CRON_LINE"
} | crontab -
rm -f "$TMP"

echo "→ verifying crontab"
crontab -l | grep -A1 'u35-manual-data-freshness'

echo "→ firing test message NOW"
"$SCRIPT"

echo
echo "✓ done. Daily message will fire at 08:00."
