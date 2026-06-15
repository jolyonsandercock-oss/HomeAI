#!/bin/bash
# claude-desk.sh — desktop Claude Code with session-level auto-resume.
#
# Runs `claude` interactively in your terminal. If the session DROPS (process
# exits non-zero — e.g. the API socket died and took the process with it), it
# relaunches with `--continue` so the conversation resumes with full context.
# A clean exit (rc=0 — you typed /exit or Ctrl-D) ends normally.
#
# SCOPE / honesty: this recovers a FULL session drop. It does NOT auto-recover a
# mid-turn "socket connection was closed unexpectedly" that the CLI surfaces while
# the process stays alive — those are handled by Claude Code's own internal retry.
# A crash loop is capped: 3 restarts within 2 minutes → stop.
#
# Usage:  bash /home_ai/scripts/claude-desk.sh   [any claude args]
#   or add an alias:  alias claude-desk='bash /home_ai/scripts/claude-desk.sh'
set -u
fails=0
window=$(date +%s)
args=("$@")
while :; do
  claude "${args[@]}"
  rc=$?
  [ "$rc" -eq 0 ] && { echo "claude-desk: clean exit." >&2; break; }
  now=$(date +%s)
  [ $((now - window)) -gt 120 ] && { fails=0; window=$now; }
  fails=$((fails + 1))
  if [ "$fails" -ge 3 ]; then
    echo "claude-desk: 3 drops in 2 min — stopping to avoid a crash loop. Resume manually: claude --continue" >&2
    break
  fi
  echo "claude-desk: session dropped (rc=$rc) — resuming with --continue in 2s…" >&2
  sleep 2
  args=(--continue)   # every relaunch resumes the most recent conversation
done
