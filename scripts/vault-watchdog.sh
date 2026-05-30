#!/bin/bash
# vault-watchdog.sh — page Telegram directly when vault seal state changes,
# and write the current state to vault_seal_state for the Mission Control
# tile / `vault_status` slug.
#
# Runs out of band from the n8n notify-bridge so it can alert about vault
# being sealed (which would break notify-bridge itself). Reads its own
# Telegram creds from a local file — no vault dependency at all.

set -uo pipefail

CREDS=/home_ai/security/.vault-watchdog-creds
STATE_DIR=/var/lib/vault-watchdog
STATE_FILE="$STATE_DIR/last-state"
VAULT_CONTAINER=homeai-vault
PG_CONTAINER=homeai-postgres

[[ -r "$CREDS" ]] || { echo "✗ $CREDS unreadable"; exit 1; }
mkdir -p "$STATE_DIR"

# shellcheck source=/dev/null
. "$CREDS"
[[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]] \
  || { echo "✗ creds file missing TG_BOT_TOKEN or TG_CHAT_ID"; exit 1; }

tg() {
  curl -sS --max-time 10 \
    -d "chat_id=$TG_CHAT_ID" \
    -d "parse_mode=HTML" \
    -d "disable_web_page_preview=true" \
    --data-urlencode "text=$1" \
    "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" >/dev/null
}

# Detect state. Treat container-down as a third state ('down').
if ! docker inspect "$VAULT_CONTAINER" >/dev/null 2>&1; then
  CURRENT=down
else
  STATUS_JSON=$(docker exec "$VAULT_CONTAINER" vault status -format=json 2>/dev/null)
  if [[ -z "$STATUS_JSON" ]]; then
    CURRENT=down
  elif printf '%s' "$STATUS_JSON" | grep -q '"sealed": *true'; then
    CURRENT=sealed
  elif printf '%s' "$STATUS_JSON" | grep -q '"sealed": *false'; then
    CURRENT=unsealed
  else
    CURRENT=unknown
  fi
fi

LAST=$(cat "$STATE_FILE" 2>/dev/null || echo "")
HOST=$(hostname -s)
NOW=$(date -Iseconds)

# Always write the current state to postgres so the slug + Mission Control
# tile have fresh data, even on no-transition ticks.
if docker inspect "$PG_CONTAINER" >/dev/null 2>&1; then
  if [[ -n "$LAST" && "$LAST" != "$CURRENT" ]]; then
    docker exec "$PG_CONTAINER" psql -U postgres -d homeai -tA -c \
      "UPDATE vault_seal_state
          SET state='$CURRENT',
              prev_state='$LAST',
              checked_at=NOW(),
              last_change_at=NOW()
        WHERE id=1;" >/dev/null 2>&1 || true
  else
    docker exec "$PG_CONTAINER" psql -U postgres -d homeai -tA -c \
      "UPDATE vault_seal_state
          SET state='$CURRENT',
              checked_at=NOW()
        WHERE id=1;" >/dev/null 2>&1 || true
  fi
fi

if [[ "$LAST" == "$CURRENT" ]]; then
  exit 0
fi

# First run after install: record only, no page.
if [[ -z "$LAST" ]]; then
  echo "$CURRENT" > "$STATE_FILE"
  exit 0
fi

# Transition — page.
case "$CURRENT" in
  sealed)
    MSG="🚨 <b>Vault sealed</b> on <code>$HOST</code> at $NOW
Ingest pipelines and notify-bridge will silently fail until unsealed.
Run: <code>sudo bash /home_ai/security/u35-vault-recovery.sh</code>"
    ;;
  down)
    MSG="🚨 <b>Vault container down</b> on <code>$HOST</code> at $NOW
docker inspect $VAULT_CONTAINER reports missing or unresponsive."
    ;;
  unsealed)
    MSG="✓ <b>Vault unsealed</b> on <code>$HOST</code> at $NOW (was: $LAST)"
    ;;
  *)
    MSG="ℹ Vault state on <code>$HOST</code>: $LAST → $CURRENT at $NOW"
    ;;
esac

if tg "$MSG"; then
  echo "$CURRENT" > "$STATE_FILE"
  echo "$NOW page sent: $LAST → $CURRENT"
else
  echo "$NOW ✗ tg send failed for transition $LAST → $CURRENT (state not advanced)"
  exit 1
fi
