#!/usr/bin/env bash
# hermes-safe: read-only view of recent dead letters (no requeue from here —
# requeueing is a Claude Code / Jo decision).
set -euo pipefail
echo "$(date -Is) show-dead-letters" >> /home_ai/logs/hermes-safe.log
docker exec homeai-postgres psql -U hermes_ro -d homeai -P pager=off -c \
  "SELECT id, created_at::timestamp(0), pipeline, resolved, left(error_message,120) AS error
     FROM dead_letter
    ORDER BY created_at DESC
    LIMIT ${1:-20};"
