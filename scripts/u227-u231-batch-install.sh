#!/bin/bash
# u227-u231-batch-install.sh — installs the root-owned changes from the
# U227–U231 autonomous batch (2026-05-29). Idempotent.
#
# Run as root.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "✗ must run as root"
  exit 1
fi

install_swap() {
  local src=$1 dst=$2 perms=${3:-0700}
  if [[ ! -f "$src" ]]; then
    echo "  · $src missing — skip"
    return
  fi
  [[ -f "$dst" ]] && cp -a "$dst" "$dst.bak.$(date +%Y%m%d-%H%M%S)"
  install -m "$perms" -o root -g root "$src" "$dst"
  rm -f "$src"
  echo "  ✓ $dst (perms $perms, prev backed up)"
}

echo "→ swapping in updated vault-watchdog.sh (V205 vault_seal_state writes)"
install_swap /home_ai/scripts/vault-watchdog.sh.new /home_ai/scripts/vault-watchdog.sh 0700

echo "→ swapping in updated u35-manual-data-freshness.sh (V204 exclude_from_freshness)"
install_swap /home_ai/scripts/u35-manual-data-freshness.sh.new /home_ai/scripts/u35-manual-data-freshness.sh 0700

echo "→ test runs"
if /home_ai/scripts/vault-watchdog.sh; then
  echo "  ✓ vault-watchdog fired (state file now: $(cat /var/lib/vault-watchdog/last-state 2>/dev/null))"
fi

echo
echo "→ vault_seal_state row after tick:"
docker exec homeai-postgres psql -U postgres -d homeai -c \
  "SELECT state, checked_at, last_change_at, prev_state FROM vault_seal_state WHERE id=1;"

echo
echo "✓ batch install complete."
echo
echo "Next manual steps (Jo at the machine, when ready):"
echo "  • U227 uploads — see this morning's email (bank/card/mortgage PDFs)"
echo "  • U229+U230 — vault put + container rebuild + Playwright pairing"
echo "    see /home_ai/.claude/decisions/U229-U230-on-site-pairing-steps.md"
echo "  • U227 T4 widget — frontend tile addition + build (defer to dashboard rebuild session)"
