#!/bin/bash
# claude-day.sh — persistent daytime Claude Code session, phone-reachable.
# Runs `claude --remote-control claude-day` inside a tmux session so it
# survives disconnects; Jo drives it from the Claude mobile app / claude.ai.
# Auto-resume: on non-zero exit (API timeout / crash) relaunch with
# --continue so the conversation keeps its context. Clean /exit (rc=0) ends
# the day. Max 3 restarts per 10-min window, then give up + Telegram alert
# (quiet-unless-degraded). Cron: 07:45 weekdays, idempotent.
# Usage: claude-day.sh          start (or report already-running)
#        claude-day.sh --inner  internal: the restart loop inside tmux
set -u
SESH=claude-day
LOG=/home_ai/logs/claude-day.log
WORKDIR=/home_ai

if [ "${1:-}" = "--inner" ]; then
  fails=0; window_start=$(date +%s); args=()
  while :; do
    claude --remote-control "$SESH" "${args[@]}"
    rc=$?
    [ "$rc" -eq 0 ] && { echo "$(date -Is) clean exit — day done" >>"$LOG"; break; }
    args=(--continue)                       # resume same conversation from now on
    now=$(date +%s)
    [ $((now - window_start)) -gt 600 ] && { fails=0; window_start=$now; }
    fails=$((fails + 1))
    echo "$(date -Is) claude exited rc=$rc — restart #$fails" >>"$LOG"
    if [ "$fails" -ge 3 ]; then
      echo "$(date -Is) 3 rapid failures — giving up" >>"$LOG"
      PATH="$HOME/.local/bin:$HOME/.hermes/bin:$PATH" hermes send -q -t telegram \
        "claude-day: session crashed 3x in 10min, gave up. Attach: tmux attach -t $SESH" \
        2>>"$LOG" || true
      break
    fi
    sleep 5
  done
  exit 0
fi

mkdir -p "$(dirname "$LOG")"
if tmux has-session -t "$SESH" 2>/dev/null; then
  echo "already running — attach locally: tmux attach -t $SESH (or use the Claude app)"
  exit 0
fi
tmux new-session -d -s "$SESH" -c "$WORKDIR" "bash /home_ai/scripts/claude-day.sh --inner"
echo "$(date -Is) session started" >>"$LOG"
echo "started — pick up '$SESH' in the Claude app, or: tmux attach -t $SESH"
