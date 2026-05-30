#!/bin/bash
# hermes-reply.sh — drop a reply file into the Hermes-readable outbox.
#
# Usage:
#   echo "..." | hermes-reply.sh <subject-slug>
#   hermes-reply.sh <subject-slug> < file.md
#   hermes-reply.sh <subject-slug>             # reads stdin until EOF
#
# Writes /home/hermes-transport/claude-replies/<timestamp>_<slug>.md
#
# Requires the outbox dir to exist (joly-writable). Set up once with:
#   sudo install -d -o joly -g joly -m 0755 /home/hermes-transport/claude-replies

set -euo pipefail

SLUG=${1:?usage: hermes-reply.sh <subject-slug>  (reads body from stdin)}
OUTBOX=/home/hermes-transport/claude-replies

if [[ ! -d "$OUTBOX" ]]; then
  echo "✗ $OUTBOX missing — run setup first:" >&2
  echo "  sudo install -d -o joly -g joly -m 0755 $OUTBOX" >&2
  exit 1
fi

if [[ ! -w "$OUTBOX" ]]; then
  echo "✗ $OUTBOX not writable by $(id -un)" >&2
  exit 1
fi

# Sanitise slug — kebab-case-ish, no path separators
SLUG_CLEAN=$(printf '%s' "$SLUG" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')
[[ -n "$SLUG_CLEAN" ]] || SLUG_CLEAN=reply

TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$OUTBOX/${TS}_${SLUG_CLEAN}.md"

# Read stdin into the file. Front-matter header for orientation.
{
  printf '# Claude reply: %s\n\n' "$SLUG_CLEAN"
  printf 'Generated: %s\n\n' "$TS"
  printf '---\n\n'
  cat
} > "$OUT"

# World-readable so hermes-transport (different group) can pick it up.
chmod 0644 "$OUT"

echo "✓ $OUT"
echo "  bytes: $(stat -c %s "$OUT")"
