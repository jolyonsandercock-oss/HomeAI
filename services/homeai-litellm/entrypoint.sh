#!/bin/sh
# Read secrets from Vault Agent-rendered files into env before exec.
set -e

if [ -z "$ANTHROPIC_API_KEY" ] && [ -n "$ANTHROPIC_API_KEY_FILE" ] && [ -f "$ANTHROPIC_API_KEY_FILE" ]; then
    export ANTHROPIC_API_KEY="$(cat "$ANTHROPIC_API_KEY_FILE")"
    echo "[entrypoint] loaded ANTHROPIC_API_KEY from $ANTHROPIC_API_KEY_FILE (len ${#ANTHROPIC_API_KEY})"
fi

# TD-007: DeepSeek route (Hermes egress via this gateway). No compose
# env var wired for the *_FILE convention yet — default to the
# vault-agent-rendered path directly (same shared /run/secrets volume
# already mounted into this container).
DEEPSEEK_API_KEY_FILE="${DEEPSEEK_API_KEY_FILE:-/run/secrets/deepseek-api-key}"
if [ -z "$DEEPSEEK_API_KEY" ] && [ -f "$DEEPSEEK_API_KEY_FILE" ]; then
    export DEEPSEEK_API_KEY="$(cat "$DEEPSEEK_API_KEY_FILE")"
    echo "[entrypoint] loaded DEEPSEEK_API_KEY from $DEEPSEEK_API_KEY_FILE (len ${#DEEPSEEK_API_KEY})"
fi

exec litellm "$@"
