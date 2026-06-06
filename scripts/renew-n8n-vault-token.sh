#!/usr/bin/env bash
# renew-n8n-vault-token.sh — keep n8n's Vault token alive so the Gmail-ingest and
# invoice pipelines never lose their secret access (the recurring "email outage").
#
# Background: the n8n credential `vault-token-header` (id 0wPA4DCDuehPC9Mf) holds a
# Vault token that the "Fetch Vault Keys" node sends as X-Vault-Token. Historically
# that was a 24h token that nothing refreshed -> it expired daily -> Fetch Vault Keys
# 403 -> ingest/invoice pipelines fail -> dead-letter flood -> auto-pause. The fix is
# to make that token a RENEWABLE PERIODIC token and renew it here on a cron. Renewing
# a periodic token extends its TTL WITHOUT changing the token value, so n8n's
# encrypted credential never has to be rewritten — set once, lives forever.
#
# ONE-TIME SETUP (operator, needs a Vault admin token + n8n UI):
#   1. Mint a renewable periodic token (no max TTL while renewed within the period):
#        docker exec -e VAULT_TOKEN=<admin> homeai-vault \
#          vault token create -policy=n8n-policy -period=168h -renewable=true -field=token
#   2. n8n UI -> Credentials -> vault-token-header -> paste it as the X-Vault-Token
#      header value -> Save.  (This also fixes the current outage immediately.)
#   3. Save the SAME token to the file this script reads (joly-owned 600, like
#      .env — the renewer runs from joly's crontab, no root needed):
#        ( umask 077; printf '%s' '<token>' > /home_ai/security/.n8n-vault-token )
#
# CRON (joly crontab + scripts/crontab.snapshot.txt, inside the 168h period):
#   0 */12 * * * bash /home_ai/scripts/renew-n8n-vault-token.sh >> /home_ai/logs/renew-n8n-vault-token.log 2>&1
set -euo pipefail
umask 077

readonly TOKEN_FILE="/home_ai/security/.n8n-vault-token"
readonly VAULT_CONTAINER="homeai-vault"
readonly LOG="/home_ai/backups/n8n-token-renew.log"
ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
cleanup() { unset TOK; }
trap cleanup EXIT INT TERM

[ -r "$TOKEN_FILE" ] || { echo "$(ts) FATAL: $TOKEN_FILE missing/unreadable (run one-time setup)" >>"$LOG"; exit 1; }
TOK=$(tr -d '[:space:]' < "$TOKEN_FILE")
[ -n "$TOK" ] || { echo "$(ts) FATAL: $TOKEN_FILE empty" >>"$LOG"; exit 1; }

# Self-renew (always permitted for a renewable token; no extra privilege needed).
if out=$(docker exec -e VAULT_TOKEN="$TOK" "$VAULT_CONTAINER" \
           vault token renew -format=json 2>&1); then
  ttl=$(printf '%s' "$out" | jq -r '.auth.lease_duration // empty' 2>/dev/null)
  echo "$(ts) OK renewed n8n vault token (ttl=${ttl:-?}s)" >>"$LOG"
else
  echo "$(ts) FAIL renew: $out" >>"$LOG"
  # Surface loudly — a failed renew means the daily-outage is ~168h from recurring.
  if [ -x /home_ai/scripts/notify.sh ]; then
    /home_ai/scripts/notify.sh "n8n Vault token renew FAILED — pipelines will lose Vault access; re-mint + re-paste (scripts/renew-n8n-vault-token.sh header)" 2>/dev/null || true
  fi
  exit 1
fi
