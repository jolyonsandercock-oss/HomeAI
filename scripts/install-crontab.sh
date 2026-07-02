#!/usr/bin/env bash
# Install scripts/crontab.canonical.txt as joly's crontab, with backup + guard resync.
set -euo pipefail
cd /home_ai
SNAP=backups/crontab-replaced-$(date +%F-%H%M).txt
crontab -l > "$SNAP"
crontab scripts/crontab.canonical.txt
# cron-guard reinstalls from its snapshot — refresh it or it will revert us
GUARD_SNAP=$(grep -oE '[^ ]*crontab[^ ]*snapshot[^ ]*' scripts/homeai-cron-guard.sh | head -1 || true)
[ -n "$GUARD_SNAP" ] && cp scripts/crontab.canonical.txt "$GUARD_SNAP" && echo "guard snapshot refreshed: $GUARD_SNAP"
echo "installed $(crontab -l | grep -cvE '^#|^$') lines (backup: $SNAP)"
