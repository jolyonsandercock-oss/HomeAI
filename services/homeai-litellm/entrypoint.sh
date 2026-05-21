#!/bin/sh
# Read secrets from Vault Agent-rendered files into env before exec.
set -e

if [ -z "$ANTHROPIC_API_KEY" ] && [ -n "$ANTHROPIC_API_KEY_FILE" ] && [ -f "$ANTHROPIC_API_KEY_FILE" ]; then
    export ANTHROPIC_API_KEY="$(cat "$ANTHROPIC_API_KEY_FILE")"
    echo "[entrypoint] loaded ANTHROPIC_API_KEY from $ANTHROPIC_API_KEY_FILE (len ${#ANTHROPIC_API_KEY})"
fi

exec litellm "$@"
