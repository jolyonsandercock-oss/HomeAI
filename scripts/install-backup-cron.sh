#!/bin/bash
# /home_ai/scripts/install-backup-cron.sh
# Adds a daily 03:00 cron entry for backup-nightly.sh. Idempotent.
# Run manually: bash /home_ai/scripts/install-backup-cron.sh
#
# Output goes to /home_ai/backups/last-backup.log so you can check via:
#   tail -50 /home_ai/backups/last-backup.log
set -euo pipefail

CRON_LINE="0 3 * * * /home_ai/scripts/backup-nightly.sh >> /home_ai/backups/cron.log 2>&1"

current=$(crontab -l 2>/dev/null || true)

if echo "$current" | grep -qF "/home_ai/scripts/backup-nightly.sh"; then
  echo "✓ backup cron already installed"
  echo "$current" | grep "backup-nightly.sh"
  exit 0
fi

(printf '%s\n' "$current"; printf '%s\n' "$CRON_LINE") | grep -v '^$' | crontab -
echo "✓ installed cron line:"
echo "  $CRON_LINE"
echo
echo "Verify with: crontab -l"
echo "Manual run:  bash /home_ai/scripts/backup-nightly.sh"
