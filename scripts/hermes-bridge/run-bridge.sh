#!/bin/bash
# Daily one-way sync of Claude Code memories -> Hermes mnemosyne + SOUL.md.
#
# Sentinel interaction (deliberate): this wrapper does NOT touch the sentinel.
# The bridge writes to mnemosyne.db (NOT a watched surface) and, idempotently,
# to SOUL.md (a watched surface). In steady state the SOUL.md culture block is
# unchanged, so no drift and no alert. The block only changes when the inherited
# discipline text itself changes — and that SHOULD require a human ack: the
# sentinel's next run will alert with "Accept if legitimate: hermes-sentinel.sh
# --baseline". Auto-rebaselining here would silently absorb ANY concurrent drift
# on the other watched surfaces, defeating the sentinel — so we don't.
set -uo pipefail
LOG=/home_ai/logs/hermes-bridge.log
PY=~/.hermes/hermes-agent/venv/bin/python
echo "$(date -Is) bridge start" >> "$LOG"
"$PY" /home_ai/scripts/hermes-bridge/bridge.py >> "$LOG" 2>&1
rc=$?
echo "$(date -Is) bridge rc=$rc" >> "$LOG"
exit $rc
