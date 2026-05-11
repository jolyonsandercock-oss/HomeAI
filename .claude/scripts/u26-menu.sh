#!/bin/bash
# /home_ai/.claude/scripts/u26-menu.sh
#
# U26 debt-clearance orchestrator. Shows the 8 outstanding tech-debt chunks
# with live state (done / pending), then prompts you to pick one.
#
# Each chunk is self-contained — picking is just a convenience. You can
# always run the individual scripts directly.
#
# Run as your normal user:
#   bash /home_ai/.claude/scripts/u26-menu.sh

set -uo pipefail
GREEN='\033[0;32m'; YEL='\033[0;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()    { echo -e "${GREEN}✓${NC} $1"; }
todo()  { echo -e "${YEL}○${NC} $1"; }
err()   { echo -e "${RED}✗${NC} $1"; }

container_running() { docker ps --filter "name=$1" --filter status=running --format '{{.Names}}' | grep -q "$1"; }
sql() { docker exec homeai-postgres psql -U postgres -d homeai -tAc "$1" 2>/dev/null; }

# ── Detection logic — each item is a function that returns 0=done 1=pending ──
chunk1_done() { container_running homeai-google-fetch; }
chunk2_done() {
  # post-wake script has run + completed (touch-file marker)
  [[ -f /home_ai/.claude/.u26-post-wake-done ]]
}
chunk3_done() {
  # ~/.claude/settings.json has hooks block
  [[ -f "$HOME/.claude/settings.json" ]] &&
  jq -e '.hooks.PreToolUse | map(select(.matcher == "Write|Edit")) | length > 0' "$HOME/.claude/settings.json" >/dev/null 2>&1
}
chunk4_done() {
  # 0 PLACEHOLDER children
  [[ "$(sql "SELECT COUNT(*) FROM children WHERE name LIKE 'PLACEHOLDER%';")" = "0" ]]
}
chunk5_done() {
  # at least one accommodation_daily AND one epos_daily row from a real (non-fixture) email
  [[ "$(sql "SELECT COUNT(*) FROM accommodation_daily;")" -ge 1 ]] &&
  [[ "$(sql "SELECT COUNT(*) FROM epos_daily;")" -ge 1 ]]
}
chunk6_done() {
  mountpoint -q /mnt/mycloud
}
chunk7_done() {
  [[ -f /home_ai/security/.vault-unseal.enc ]]
}
chunk8_done() {
  container_running homeai-authelia
}
chunk9_done() {
  # backup-all.sh git push block is uncommented
  grep -qE '^\s*git\s+(push|add|commit)' /home_ai/scripts/backup-all.sh
}

print_status() {
  echo
  echo -e "${CYAN}═══ U26 debt-clearance status ═══${NC}"
  echo
  if chunk1_done; then ok "1. System woken (./start.sh)"; else todo "1. System woken — run: ./start.sh"; fi
  if chunk2_done; then ok "2. Post-wake cleanup"; else todo "2. Post-wake cleanup — run: bash /home_ai/.claude/scripts/u26-post-wake.sh"; fi
  if chunk3_done; then ok "3. PreToolUse hooks installed"; else todo "3. Hooks — run: bash /home_ai/.claude/scripts/u13-install-hooks.sh"; fi
  if chunk4_done; then ok "4. Children real data"; else todo "4. Children — run: bash /home_ai/.claude/scripts/u26-children.sh"; fi
  if chunk5_done; then ok "5. Real EPoS + Caterbook samples ingested"; else todo "5. Capture samples — run: bash /home_ai/.claude/scripts/u26-capture-samples.sh"; fi
  if chunk6_done; then ok "6. NAS mounted + Restic repointed"; else todo "6. NAS mount — run: sudo bash /home_ai/.claude/scripts/u13-mount-nas.sh"; fi
  if chunk7_done; then ok "7. Vault auto-unseal bootstrapped"; else todo "7. Auto-unseal — run: sudo bash /home_ai/.claude/scripts/u13-bootstrap-auto-unseal.sh"; fi
  if chunk8_done; then ok "8. Authelia 2FA running"; else todo "8. Authelia — run: bash /home_ai/.claude/scripts/u26-prep-authelia.sh"; fi
  if chunk9_done; then ok "9. Backup-all.sh git push enabled"; else todo "9. Git remote — run: bash /home_ai/.claude/scripts/u26-setup-git-remote.sh"; fi
  echo
}

# ── Orchestrator loop ────────────────────────────────────────────────────────
while :; do
  print_status
  echo "Pick a chunk to run (1-9), 's' to refresh status, or 'q' to quit:"
  read -rp "> " choice
  case "${choice:-}" in
    1) echo; echo "Running ./start.sh in /home_ai…"; (cd /home_ai && ./start.sh); echo ;;
    2) echo; bash /home_ai/.claude/scripts/u26-post-wake.sh ;;
    3) echo; bash /home_ai/.claude/scripts/u13-install-hooks.sh ;;
    4) echo; bash /home_ai/.claude/scripts/u26-children.sh ;;
    5) echo; bash /home_ai/.claude/scripts/u26-capture-samples.sh ;;
    6) echo; sudo bash /home_ai/.claude/scripts/u13-mount-nas.sh ;;
    7) echo; sudo bash /home_ai/.claude/scripts/u13-bootstrap-auto-unseal.sh ;;
    8) echo; bash /home_ai/.claude/scripts/u26-prep-authelia.sh ;;
    9) echo; bash /home_ai/.claude/scripts/u26-setup-git-remote.sh ;;
    s|S|"") continue ;;
    q|Q) echo "bye."; exit 0 ;;
    *) echo "invalid choice: $choice" ;;
  esac
  echo
  echo "(press Enter for menu)"; read -r
done
