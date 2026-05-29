#!/bin/bash
# pair.sh — start an in-container VNC session and run a Playwright pairing.
#
# Usage:
#   docker exec -it homeai-playwright /app/pair.sh dojo USERNAME PASSWORD
#   docker exec -it homeai-playwright /app/pair.sh trail USERNAME PASSWORD
#
# Host-side: SSH-tunnel and connect a VNC viewer:
#   ssh -L 5900:127.0.0.1:5900 joly@jolybox.tailc27dff.ts.net
#   # then point VNC viewer at localhost:5900 (no password — secured by SSH+Tailscale)

set -euo pipefail

SCRAPER=${1:?usage: pair.sh <dojo|trail> USERNAME PASSWORD}
USERNAME=${2:?missing username}
PASSWORD=${3:?missing password}

case "$SCRAPER" in
  dojo|trail) ;;
  *) echo "✗ unknown scraper: $SCRAPER (expected: dojo | trail)"; exit 2 ;;
esac

cleanup() {
  echo "→ stopping xvfb / x11vnc / fluxbox"
  pkill -P $$ 2>/dev/null || true
  pkill -f 'Xvfb :99' 2>/dev/null || true
  pkill -f 'x11vnc.*:99' 2>/dev/null || true
  pkill -f 'fluxbox' 2>/dev/null || true
}
trap cleanup EXIT INT TERM

export DISPLAY=:99

# Start Xvfb if not already running on :99
if ! pgrep -f 'Xvfb :99' >/dev/null 2>&1; then
  echo "→ starting Xvfb on :99 (1400x900)"
  Xvfb :99 -screen 0 1400x900x24 -ac +extension RANDR &
  sleep 1
fi

# Minimal WM so chromium has proper window decorations + can be moved
if ! pgrep fluxbox >/dev/null 2>&1; then
  fluxbox -display :99 >/dev/null 2>&1 &
  sleep 0.5
fi

# Start x11vnc bound to 0.0.0.0 inside the container; host publishes only
# on 127.0.0.1:5900 via compose so it's reachable from host loopback only.
# SSH tunnel + Tailscale provides the auth layer; -nopw is intentional here.
echo "→ starting x11vnc on 0.0.0.0:5900 (host-loopback only via compose)"
x11vnc -display :99 -nopw -listen 0.0.0.0 -rfbport 5900 \
       -forever -shared -bg -quiet -noxdamage 2>/dev/null || {
  echo "✗ x11vnc failed to start"; exit 1;
}

cat <<EOF

╔════════════════════════════════════════════════════════════════════╗
║ READY                                                               ║
║                                                                     ║
║ From your laptop:                                                   ║
║   ssh -L 5900:127.0.0.1:5900 joly@jolybox.tailc27dff.ts.net         ║
║                                                                     ║
║ Then open a VNC viewer pointed at:                                  ║
║   localhost:5900   (or vnc://localhost:5900 on macOS)               ║
║                                                                     ║
║ A headed Chromium will appear in ~5s. Complete the auth flow.       ║
║ When you've reached the dashboard, press Enter back in this         ║
║ terminal to save storage_state.json and exit.                       ║
╚════════════════════════════════════════════════════════════════════╝

EOF

echo "→ launching headed Playwright pair for: $SCRAPER"
cd /app
python3 -m "scrapers.$SCRAPER" --pair --username "$USERNAME" --password "$PASSWORD"

echo
echo "✓ pairing complete. storage_state.json saved under /home_ai/data/playwright-state/"
echo "  test a headless run: curl -sX POST http://localhost:8001/ingest/$SCRAPER"
