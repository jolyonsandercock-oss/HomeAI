#!/bin/bash
# Rotates secret/signing.payload_hmac_key + secret/redis.password.
# Generates hex (paste-safe), patches Vault, prints next steps.
# Does NOT recreate containers — that's start.sh's job (needs your env).
set -euo pipefail

NEW_SIGNING=$(openssl rand -hex 32)
NEW_REDIS=$(openssl rand -hex 24)

docker exec -e VAULT_TOKEN homeai-vault \
  vault kv patch secret/signing payload_hmac_key="$NEW_SIGNING" >/dev/null

docker exec -e VAULT_TOKEN homeai-vault \
  vault kv patch secret/redis password="$NEW_REDIS" >/dev/null

unset NEW_SIGNING NEW_REDIS

cat <<'NOTE'
✓ Rotated:
   - secret/signing.payload_hmac_key
   - secret/redis.password

Both stored in Vault. Not echoed.

Next: run ./start.sh

It will recreate the services that need the new values:
   - redis  (compose interpolates ${REDIS_PASSWORD}; redis itself needs new pw)
   - llm-router (uses both PAYLOAD_HMAC_KEY and REDIS_PASSWORD)
   - model-evaluator (uses PAYLOAD_HMAC_KEY)
   - n8n (uses signing key in workflows, via env)
   - open-webui (uses redis — verify it reconnects)

Caveats:
- Event signatures generated before this rotation will NOT verify against the
  new key. Acceptable — events keep their original signatures; new events sign
  with the new key. No re-signing of historical events.
- If start.sh fails to bring redis back up, check 'docker logs homeai-redis'
  for "WRONGPASS" — would mean the redis volume retained the old password and
  you need 'docker compose down redis && docker volume rm home_ai_redis_data'
  (only if redis volume isn't holding state you care about — for a freshly-
  built system, it's just cache).
NOTE
