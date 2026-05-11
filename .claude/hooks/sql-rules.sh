#!/bin/bash
# PreToolUse hook for Write/Edit — enforce SQL discipline rules from AGENTS.md.
#
# Rules enforced:
#   1. INSERT INTO events MUST include payload_signature column
#      (catches "ALWAYS sign event payloads (HMAC-SHA256) before INSERT")
#   2. INSERT/UPDATE on entity-scoped tables MUST be preceded by
#      SET LOCAL app.current_entity OR set_config('app.current_entity', ...)
#      OR be inside a SECURITY DEFINER function definition.
#
# Triggers: only fires when the file or content looks like SQL (.sql path or
# explicit INSERT INTO events|emails|invoices|... in the body). Skips
# obviously-test files (path contains /tests/ or /spec/ or /examples/).
#
# Best-effort static analysis. Does NOT catch every form, but catches the
# common shape that AGENTS.md is most worried about (a raw INSERT without
# the discipline).
set -euo pipefail

INPUT=$(cat)
PATH_=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""')
CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // ""')

# Only run on SQL-ish content
if ! echo "$PATH_" | grep -qE '\.(sql|md|json|yaml|yml|sh|py|js|ts)$' \
   && ! echo "$CONTENT" | grep -qiE 'INSERT[[:space:]]+INTO|UPDATE[[:space:]]+events'; then
  exit 0
fi

# Skip test fixtures / spec files
if echo "$PATH_" | grep -qE '/(tests|test|spec|examples|fixtures)/'; then
  exit 0
fi

# 1. INSERT INTO events without payload_signature
if echo "$CONTENT" | grep -qiE 'INSERT[[:space:]]+INTO[[:space:]]+events[[:space:]]*[(]'; then
  if ! echo "$CONTENT" | grep -qiE 'payload_signature'; then
    echo "[hook:sql-rules] BLOCKED — INSERT INTO events without payload_signature column. AGENTS.md rule: ALWAYS sign event payloads (HMAC-SHA256) before INSERT." >&2
    exit 2
  fi
fi

# 2. Naive RLS check on entity-scoped tables
ENTITY_TABLES_RX='emails|invoices|bank_transactions|epos_daily_reports|till_reconciliation|accommodation_daily_reports|child_events|rent_payments|documents'
if echo "$CONTENT" | grep -qiE "INSERT[[:space:]]+INTO[[:space:]]+($ENTITY_TABLES_RX)\b"; then
  if ! echo "$CONTENT" | grep -qiE "SET[[:space:]]+LOCAL[[:space:]]+app\.current_entity|set_config\([[:space:]]*'app\.current_entity'|SECURITY[[:space:]]+DEFINER"; then
    echo "[hook:sql-rules] BLOCKED — INSERT into RLS-scoped table without SET LOCAL app.current_entity / set_config / SECURITY DEFINER context. AGENTS.md rule." >&2
    exit 2
  fi
fi

exit 0
