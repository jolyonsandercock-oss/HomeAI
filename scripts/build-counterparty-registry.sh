#!/usr/bin/env bash
# build-counterparty-registry.sh — (re)build the counterparties registry. Idempotent.
# Safe to run from cron; pure SQL, no LLM. See docs/superpowers/specs/2026-06-05-*.
set -euo pipefail
docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 \
  -c "SELECT home_ai.build_counterparty_registry();"
echo "✓ counterparty registry built ($(docker exec -i homeai-postgres psql -U postgres -d homeai -tAc \
  "select count(*) from counterparties"))"
