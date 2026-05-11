#!/bin/bash
# /home_ai/scripts/u27-codegen.sh
#
# Workaround for Playwright not shipping browser binaries for ubuntu26.04-x64.
# Runs `playwright codegen` inside the homeai-playwright image (which has
# Chromium pre-installed for noble), with the host X display forwarded so the
# Inspector + browser windows appear on your desktop.
#
# Recorded async-Python script lands on the host at /tmp/u27-<name>-flow.py.
#
# Usage:
#   ./scripts/u27-codegen.sh <name> [URL]
#
# Examples:
#   ./scripts/u27-codegen.sh touchoffice https://touchoffice.net
#   ./scripts/u27-codegen.sh caterbook   https://app.caterbook.net
#
# Tip — when the Inspector opens, click "Record" if it isn't already on,
# drive the flow you want to capture, then close the browser window.

set -euo pipefail
RED='\033[0;31m'; YEL='\033[0;33m'; GREEN='\033[0;32m'; NC='\033[0m'

NAME=${1:-}
URL=${2:-}
[[ -z "$NAME" ]] && { echo "usage: $0 <name> [URL]"; exit 1; }

OUTFILE_HOST=/tmp/u27-${NAME}-flow.py
IMAGE=home_ai-playwright-service:latest
NETWORK=home_ai_ai-egress

[[ -n "${DISPLAY:-}" ]] || {
  echo -e "${RED}✗${NC} no \$DISPLAY set — run from a graphical session"; exit 1; }
[[ -d /tmp/.X11-unix ]] || {
  echo -e "${RED}✗${NC} /tmp/.X11-unix missing — Xwayland not running"; exit 1; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo -e "${RED}✗${NC} image $IMAGE not built — run: docker compose build playwright-service"; exit 1; }

# Allow local Docker UIDs to talk to the host X server; revoke on exit.
xhost +local:docker >/dev/null 2>&1 || {
  echo -e "${RED}✗${NC} xhost +local:docker failed"; exit 1; }
trap 'xhost -local:docker >/dev/null 2>&1 || true' EXIT INT TERM

echo -e "${YEL}→${NC} launching codegen in container (Inspector + browser will open on $DISPLAY)…"
echo "    Drive the browser through the flow you want to record."
echo "    Close the browser window when done — the recorded script saves to:"
echo "      $OUTFILE_HOST"
echo

docker run --rm -it \
  --network "$NETWORK" \
  --shm-size=2g \
  -e DISPLAY="$DISPLAY" \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
  -v /tmp:/host-tmp:rw \
  "$IMAGE" \
  python -m playwright codegen \
    --target python-async \
    --output "/host-tmp/u27-${NAME}-flow.py" \
    ${URL:+"$URL"}

if [[ -s "$OUTFILE_HOST" ]]; then
  echo -e "${GREEN}✓${NC} recorded: $OUTFILE_HOST"
  ls -la "$OUTFILE_HOST"
else
  echo -e "${YEL}!${NC} no output produced — did the browser close before any actions?"
fi
