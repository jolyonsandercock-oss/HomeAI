#!/bin/bash
# /home_ai/scripts/bootstrap.sh — prepare fresh Ubuntu 26.04 for Home AI.
#
# Idempotent. Safe to re-run on an already-bootstrapped machine — every step
# checks before acting. Dry-run mode (`--dry-run`) prints what it would do.
#
# What this DOES:
#   1. apt installs base packages (docker, git, curl, age, openssh, ufw, restic, jq)
#   2. Installs nvidia-container-toolkit if NVIDIA GPU detected
#   3. Adds current user to docker group (idempotent)
#   4. Installs Tailscale (idempotent)
#   5. Configures UFW: tailnet-only inbound (idempotent)
#
# What it does NOT do (deliberately — these need decisions):
#   - clone the repo (you're already running it)
#   - sudo tailscale up (interactive auth)
#   - download Ollama models (huge — pull them after start.sh works)
#   - run start.sh (needs Vault unseal keys)
#
# Usage:
#   sudo bash /home_ai/scripts/bootstrap.sh           # apply
#   bash      /home_ai/scripts/bootstrap.sh --dry-run # show without applying

set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

run() {
  if $DRY_RUN; then
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

need_sudo() {
  if [[ $EUID -ne 0 ]] && ! $DRY_RUN; then
    echo "✗ this step needs sudo — re-run as: sudo bash $0"
    exit 1
  fi
}

echo "── Home AI bootstrap ($($DRY_RUN && echo 'dry-run' || echo 'live')) ──"
echo

# ── 1. apt packages ─────────────────────────────────────────────
echo "→ apt packages"
PKGS=(docker.io docker-compose-v2 docker-buildx git curl age openssh-server ufw restic jq)
MISSING=()
for p in "${PKGS[@]}"; do
  dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p")
done
if [[ ${#MISSING[@]} -eq 0 ]]; then
  echo "  ✓ all base packages already installed"
else
  echo "  installing: ${MISSING[*]}"
  need_sudo
  run apt-get update -y
  run apt-get install -y --no-install-recommends "${MISSING[@]}"
fi

# ── 2. NVIDIA container toolkit (only if GPU present) ──────────
echo "→ NVIDIA toolkit"
if lspci 2>/dev/null | grep -qi 'NVIDIA'; then
  if dpkg -s nvidia-container-toolkit >/dev/null 2>&1; then
    echo "  ✓ nvidia-container-toolkit already installed"
  else
    echo "  installing nvidia-container-toolkit"
    need_sudo
    # NVIDIA's stable repo
    run bash -c 'curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg'
    run bash -c 'curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" > /etc/apt/sources.list.d/nvidia-container-toolkit.list'
    run apt-get update -y
    run apt-get install -y nvidia-container-toolkit
    run systemctl restart docker
  fi
else
  echo "  (no NVIDIA GPU detected — skipping)"
fi

# ── 3. docker group membership ─────────────────────────────────
echo "→ docker group"
ME="${SUDO_USER:-$USER}"
if id -nG "$ME" 2>/dev/null | grep -qw docker; then
  echo "  ✓ $ME already in docker group"
else
  echo "  adding $ME to docker group"
  need_sudo
  run usermod -aG docker "$ME"
  echo "  ⚠ logout/login required for group change to take effect"
fi

# ── 4. Tailscale ────────────────────────────────────────────────
echo "→ Tailscale"
if command -v tailscale >/dev/null 2>&1; then
  echo "  ✓ tailscale installed"
else
  echo "  installing tailscale"
  need_sudo
  run bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
  echo "  ⚠ next: sudo tailscale up    (interactive — authenticates with your account)"
fi

# ── 5. UFW: tailnet-only inbound ───────────────────────────────
echo "→ UFW"
if command -v ufw >/dev/null 2>&1; then
  if ufw status 2>/dev/null | grep -q 'Status: active'; then
    echo "  ✓ ufw active"
  else
    echo "  configuring ufw — tailnet-only inbound"
    need_sudo
    run ufw default deny incoming
    run ufw default allow outgoing
    run ufw allow in on tailscale0
    run ufw allow ssh
    run ufw --force enable
  fi
else
  echo "  ⚠ ufw not installed (apt step should have done this)"
fi

# ── Done ────────────────────────────────────────────────────────
echo
echo "── bootstrap complete ──"
echo
echo "Manual next steps (in order):"
echo "  1. logout + login (if docker group was added)"
echo "  2. sudo tailscale up                    # authenticate with your tailnet"
echo "  3. cd /home_ai && ./start.sh             # unseal Vault, fetch secrets, bring services up"
echo "  4. (optional) docker exec homeai-ollama ollama pull qwen2.5:7b   # 4.4 GB hot tier"
echo "  5. /home_ai/scripts/restore.sh BACKUP_DIR  # if recovering from backup"
