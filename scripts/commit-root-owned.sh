#!/bin/bash
# commit-root-owned.sh — sudo-friendly commit for the 4 root-owned scripts
# that I (Claude) couldn't `git add` directly during today's tidy-up.
#
#   sudo bash /home_ai/scripts/commit-root-owned.sh
#
# These files are root-owned 0700 by design (vault-watchdog reads the
# Telegram creds file at /home_ai/security/.vault-watchdog-creds which is
# also root-only). They were installed via u35-vault-watchdog-install.sh
# and u35-manual-data-freshness-install.sh respectively.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "✗ must run as root (so git can stat root-owned files)"
  exit 1
fi

cd /home_ai

git add \
  scripts/vault-watchdog.sh \
  scripts/vault-watchdog.service \
  scripts/vault-watchdog.timer \
  scripts/u35-manual-data-freshness.sh

# Hand commit-author config back to joly so the commit isn't attributed
# to root@JolyBox. -c flag overrides for this commit only.
git -c user.name='Jolyon Sandercock' \
    -c user.email='jolyon.sandercock@gmail.com' \
    commit -m "$(cat <<'EOF'
Vault watchdog + manual-data freshness — root-owned scripts

Root-owned 0700 by design so they can read /home_ai/security/.vault-
watchdog-creds (also root:root 0600). Installed via:
- scripts/u35-vault-watchdog-install.sh    (vault-watchdog timer)
- scripts/u35-manual-data-freshness-install.sh (08:00 daily cron)

Companion to commits:
- Vault recovery (2026-05-28) — recovery script + identity-mode autounseal
- U227 + U228: manual-data freshness + alerting completeness

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"

echo "✓ committed."
