#!/bin/bash
# u236-hermes-outbox-setup.sh — one-shot to create the Hermes-readable outbox
# that lets Claude push replies back into the same /home/hermes-transport
# pipeline (closing the 4-eyes asymmetry).
#
#   sudo bash /home_ai/scripts/u236-hermes-outbox-setup.sh
#
# After this runs, the laptop-side Hermes SSH polling should be configured
# to read /home/hermes-transport/claude-replies/ in the same way it writes
# to /home/hermes-transport/hermes-reviews/. Add to Hermes's drop script:
#
#   rsync -av --remove-source-files \
#     joly@jolybox.tailc27dff.ts.net:/home/hermes-transport/claude-replies/ \
#     ~/hermes-inbox/claude-replies/

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "✗ must run as root" >&2
  exit 1
fi

OUTBOX=/home/hermes-transport/claude-replies

# Owned by joly so the Claude session (running as joly) can write directly.
# World-readable so hermes-transport (different user, different group) can
# pick them up via its SSH session.
install -d -o joly -g joly -m 0755 "$OUTBOX"

# Stricter: write-protect the dir from hermes-transport — they should only
# read + consume. Keep g+w off, w-other off (default umask handles it).

echo "✓ outbox ready: $OUTBOX"
echo "  perms: $(stat -c '%U:%G %a' "$OUTBOX")"
echo
echo "Test by dropping a reply:"
echo "  echo 'hello hermes' | /home_ai/scripts/hermes-reply.sh test"
echo
echo "On your laptop, configure Hermes to rsync this dir into its inbox."
