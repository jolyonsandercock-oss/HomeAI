#!/bin/bash
# /home_ai/.claude/scripts/u13-install-hooks.sh
#
# U13 Stage D — install Claude Code PreToolUse hooks in YOUR ~/.claude/settings.json.
#
# Why this script exists:
#   Claude (the agent) cannot self-modify ~/.claude/settings.json — that's a
#   safety boundary. So the user runs this once and it's done.
#
# What this does (idempotent):
#   1. Backs up ~/.claude/settings.json to ~/.claude/settings.json.bak.<ts>
#   2. Merges the PreToolUse hooks block into your existing settings (does NOT
#      overwrite other settings; uses jq to do an in-place merge)
#   3. Runs two negative tests proving the hooks are wired
#
# Run as your normal user (NOT root):
#   bash /home_ai/.claude/scripts/u13-install-hooks.sh

set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "✗ run as your normal user, not root"
  exit 1
fi

SETTINGS="$HOME/.claude/settings.json"
HOOKS_DIR="/home_ai/.claude/hooks"
NO_SECRETS="$HOOKS_DIR/no-secrets-in-files.sh"
SQL_RULES="$HOOKS_DIR/sql-rules.sh"

# ── Sanity ────────────────────────────────────────────────────────
[[ -x "$NO_SECRETS" ]] || { echo "✗ $NO_SECRETS missing or not executable"; exit 1; }
[[ -x "$SQL_RULES"  ]] || { echo "✗ $SQL_RULES missing or not executable";  exit 1; }
command -v jq >/dev/null 2>&1 || { echo "✗ install jq first (sudo apt-get install jq)"; exit 1; }

if [[ ! -f "$SETTINGS" ]]; then
  echo "✗ no $SETTINGS — Claude Code hasn't run on this account yet?"
  echo "  start Claude Code once, then re-run this script."
  exit 1
fi

# ── Backup ────────────────────────────────────────────────────────
TS=$(date +%s)
BACKUP="$SETTINGS.bak.$TS"
cp "$SETTINGS" "$BACKUP"
echo "✓ backed up to $BACKUP"

# ── Merge hooks block ─────────────────────────────────────────────
# Strategy: read existing settings.json, merge a new "hooks" key. If the
# user already has a hooks.PreToolUse array, we APPEND our two commands rather
# than replace the array — but only if they aren't already there.
TMP=$(mktemp)
jq --arg ns "$NO_SECRETS" --arg sr "$SQL_RULES" '
  .hooks //= {}
  | .hooks.PreToolUse //= []
  | .hooks.PreToolUse |= (
      # Find the matcher entry for "Write|Edit", or create one
      (map(select(.matcher == "Write|Edit")) | length) as $existing
      | if $existing == 0 then
          . + [{
            matcher: "Write|Edit",
            hooks: [
              { type: "command", command: $ns },
              { type: "command", command: $sr }
            ]
          }]
        else
          map(
            if .matcher == "Write|Edit" then
              .hooks //= []
              | .hooks |= (
                  . + (
                    [{ type: "command", command: $ns }, { type: "command", command: $sr }]
                    | map(select(. as $candidate
                        | ($candidate | tojson) as $c
                        | (. | tojson) | contains($c) | not))
                  )
                )
            else . end
          )
        end
    )
' "$SETTINGS" > "$TMP"

if ! jq -e . "$TMP" >/dev/null 2>&1; then
  echo "✗ merge produced invalid JSON — keeping original. See $TMP for the bad output."
  exit 1
fi

mv "$TMP" "$SETTINGS"
echo "✓ merged hooks block into $SETTINGS"
echo
echo "Resulting hooks block:"
jq '.hooks' "$SETTINGS"
echo

# ── Negative tests (prove the hooks would block bad writes) ────────
echo "── Sanity tests ──"

run_hook_test() {
  local label="$1"
  local hook_script="$2"
  local payload="$3"
  local out
  if out=$(echo "$payload" | "$hook_script" 2>&1); then
    echo "  ✗ $label: hook accepted what it should have blocked"
    echo "    output: $out"
    return 1
  else
    echo "  ✓ $label: hook correctly blocked"
    return 0
  fi
}

PASS=0; FAIL=0

# Test 1: no-secrets hook should block writes to *.env
run_hook_test "no-secrets blocks .env path" "$NO_SECRETS" \
  '{"tool_input":{"file_path":"/tmp/test-secret.env","content":"PASSWORD=hunter2"}}' \
  && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# Test 2: sql-rules hook should block events INSERT without payload_signature
run_hook_test "sql-rules blocks unsigned events INSERT" "$SQL_RULES" \
  '{"tool_input":{"file_path":"/tmp/test.sql","content":"INSERT INTO events (event_type) VALUES ('"'"'foo'"'"');"}}' \
  && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo
echo "── DONE — $PASS pass, $FAIL fail ──"
echo
if [[ $FAIL -eq 0 ]]; then
  echo "Restart Claude Code (or open a new session) so the new hooks load."
  echo "If anything goes wrong, restore the previous settings with:"
  echo "  cp '$BACKUP' '$SETTINGS'"
else
  echo "✗ one or more sanity tests failed. Settings file is updated but hooks may"
  echo "  not be doing what you want. Review $SETTINGS or restore the backup:"
  echo "  cp '$BACKUP' '$SETTINGS'"
  exit 1
fi
