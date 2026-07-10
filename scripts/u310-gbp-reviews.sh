#!/usr/bin/env bash
# u310-gbp-reviews.sh — wrapper for the Google Business Profile reviews sync.
# Runs the python inside homeai-google-fetch (Vault + googleapis egress + PG_DSN).
# Prereq: Vault secret/gbp holds {client_id, client_secret, refresh_token}
#   (one-time owner setup — see docs/superpowers/plans/2026-07-10-review-apis-*.md).
set -euo pipefail

VAULT_TOKEN=$(docker inspect homeai-google-fetch \
  --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" homeai-google-fetch \
  python3 - < /home_ai/scripts/u310-gbp-reviews.py
