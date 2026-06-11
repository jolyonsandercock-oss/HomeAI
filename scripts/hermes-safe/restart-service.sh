#!/usr/bin/env bash
# hermes-safe: restart one allowlisted stateless container.
# Core stateful services (postgres, vault, n8n, caddy, authelia, redis,
# metabase) are deliberately NOT restartable from here — those go through
# Claude Code or Jo. Uses `docker restart` (never recreate: see
# feedback_metabase_empty_db_pass for why recreate outside start.sh is unsafe).
set -euo pipefail

ALLOWED="homeai-searxng homeai-ollama homeai-pdfplumber homeai-markitdown homeai-playwright homeai-google-fetch homeai-grafana homeai-wa-bridge homeai-frontend homeai-build-dashboard homeai-data-proxy homeai-mcp homeai-llm-router homeai-bot-responder homeai-model-evaluator"

name="${1:-}"
if [[ -z "$name" ]]; then
  echo "usage: restart-service.sh <container>"; echo "allowed: $ALLOWED"; exit 2
fi
ok=0
for a in $ALLOWED; do [[ "$name" == "$a" ]] && ok=1; done
if [[ "$ok" != 1 ]]; then
  echo "REFUSED: '$name' is not on the hermes-safe restart allowlist."
  echo "allowed: $ALLOWED"; exit 3
fi
echo "$(date -Is) restart-service $name" >> /home_ai/logs/hermes-safe.log
docker restart "$name"
sleep 3
docker ps --filter "name=^${name}$" --format '{{.Names}} {{.Status}}'
