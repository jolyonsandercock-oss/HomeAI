#!/usr/bin/env bash
# §BUILD-LOCAL-FIRST helper — routes Explore sub-tasks to qwen2.5:7b
# Usage:
#   Echo mode:   ./local-query.sh "your question here"
#   Pipe mode:   ./local-query.sh "your question" < file.sql
#   Inline mode: cat file.py | ./local-query.sh "list all endpoints"
#
# Exit codes: 0 = success, 1 = ollama unreachable, 2 = empty response

set -euo pipefail

OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
MODEL="${LOCAL_QUERY_MODEL:-qwen2.5:7b}"
QUESTION="${1:-}"
TIMEOUT="${LOCAL_QUERY_TIMEOUT:-30}"

if [[ -z "$QUESTION" ]]; then
  echo "Usage: local-query.sh \"question\" [< optional_file]" >&2
  exit 1
fi

# Check Ollama is reachable
if ! curl -sf --max-time 3 "${OLLAMA_URL}/api/tags" > /dev/null 2>&1; then
  echo "[LOCAL-QUERY ERROR] Ollama unreachable at ${OLLAMA_URL}" >&2
  exit 1
fi

# Read optional stdin context
CONTEXT=""
if [[ ! -t 0 ]]; then
  CONTEXT=$(cat)
fi

# Build prompt
if [[ -n "$CONTEXT" ]]; then
  PROMPT="Answer concisely and factually. Do not explain your reasoning unless asked.\n\nFile content:\n${CONTEXT}\n\nQuestion: ${QUESTION}"
else
  PROMPT="Answer concisely and factually. Do not explain your reasoning unless asked.\n\nQuestion: ${QUESTION}"
fi

# Call Ollama
RESPONSE=$(curl -sf --max-time "${TIMEOUT}" "${OLLAMA_URL}/api/generate" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"prompt\":$(echo "$PROMPT" | jq -Rs .),\"stream\":false}" \
  | jq -r '.response // empty')

if [[ -z "$RESPONSE" ]]; then
  echo "[LOCAL-QUERY ERROR] Empty response from model" >&2
  exit 2
fi

echo "$RESPONSE"
