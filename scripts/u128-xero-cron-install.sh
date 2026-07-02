#!/usr/bin/env bash
# u128-xero-cron-install.sh — idempotently add U128 cron entries.
#
# Schedule:
#   06:45  headless Xero export   (tries; Akamai may bounce after session decays)
#   07:00  parse any Bills_*.csv in /home_ai/data/xero-inbox + the day's export
#   07:30  forward orphans aged >7d to malthousepub@dext.cc
#
# Manual fallback: Jo drops a Bills_*.csv from the Xero UI into
# /home_ai/data/xero-inbox  → cron picks it up at 07:00 the next morning.

set -euo pipefail

mkdir -p /home_ai/logs /home_ai/data/xero-inbox/.processed

# Build new crontab: keep everything that ISN'T a u128 line, then append fresh ones.
NEW=$(mktemp); trap 'rm -f "$NEW"' EXIT
crontab -l 2>/dev/null | grep -v -E "u128|xero-(export|parse|cron-install|forward)" > "$NEW"

cat >>"$NEW" <<'EOF'

# u128 — daily Xero export + parse + orphan forward
45 6 * * * /home_ai/scripts/u128-xero-export.sh >> /home_ai/logs/u128-xero-export.log 2>&1
 0 7 * * * cp /home_ai/data/xero-exports/xero-bills-$(date +\%Y-\%m-\%d).csv /home_ai/data/xero-inbox/ 2>/dev/null; /home_ai/scripts/u128-xero-parse.sh >> /home_ai/logs/u128-xero-parse.log 2>&1
30 7 * * * /home_ai/scripts/u128-forward-orphans.sh --limit 20 >> /home_ai/logs/u128-forward-orphans.log 2>&1
EOF

crontab "$NEW"
echo "✓ Installed U128 cron entries:"
crontab -l | grep "u128" | head -5
