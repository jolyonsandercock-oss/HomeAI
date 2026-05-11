#!/bin/bash
# /home_ai/scripts/log-build-activity.sh
# Record a "Build Layer" entry into model_usage_history.
# Called from Claude Code Bash tool to instrument what the agent is doing.
#
# Usage:
#   log-build-activity.sh "summary text" [model] [tokens_in] [tokens_out]
#
# Example:
#   log-build-activity.sh "refactored index.html (heartbeat bar)" claude-opus-4-7 0 1842
#
# Defaults:
#   model       = $CLAUDE_MODEL_OVERRIDE or 'claude-opus-4-7'
#   tokens_in   = 0
#   tokens_out  = 0
#
# Tier mapping is inferred from model name. Provider always 'anthropic' for
# the build layer (Claude Code IS Anthropic-hosted).

set -euo pipefail

SUMMARY="${1:?usage: log-build-activity.sh <summary> [model] [tokens_in] [tokens_out]}"
MODEL="${2:-${CLAUDE_MODEL_OVERRIDE:-claude-opus-4-7}}"
TOK_IN="${3:-0}"
TOK_OUT="${4:-0}"

# Tier classification — keep aligned with V18's tiers_v2
case "$MODEL" in
  claude-opus-4-7*)   TIER='apex' ;;
  claude-opus-4-6*)   TIER='legacy_apex' ;;
  claude-haiku-*)     TIER='cloud_speed' ;;
  claude-sonnet-*)    TIER='cloud_speed' ;;
  phi4*)              TIER='local_logic' ;;
  qwen*|llama*|mistral*|gemma*) TIER='local_fast' ;;
  *)                  TIER='manual' ;;
esac

case "$MODEL" in
  claude-*) PROVIDER='anthropic' ;;
  *)        PROVIDER='local' ;;
esac

# Anthropic Haiku-ish pricing for cost estimate (more aggressive for Opus)
case "$MODEL" in
  claude-opus-4-7*)   PER_IN_GBP=0.01185;   PER_OUT_GBP=0.0593   ;;  # ~$15/$75 per MTok @ 0.79
  claude-opus-4-6*)   PER_IN_GBP=0.01185;   PER_OUT_GBP=0.0593   ;;
  claude-sonnet-4-6*) PER_IN_GBP=0.00237;   PER_OUT_GBP=0.01185  ;;  # ~$3/$15
  claude-haiku-*)     PER_IN_GBP=0.000632;  PER_OUT_GBP=0.00316  ;;  # ~$0.80/$4
  *)                  PER_IN_GBP=0;         PER_OUT_GBP=0        ;;
esac

# Per 1k tokens — cost = (in/1000)*PER_IN + (out/1000)*PER_OUT
COST=$(awk -v ti="$TOK_IN" -v to="$TOK_OUT" -v pi="$PER_IN_GBP" -v po="$PER_OUT_GBP" \
       'BEGIN { printf "%.6f", (ti/1000)*pi + (to/1000)*po }')

# Escape for SQL
SUMMARY_ESC=$(printf '%s' "$SUMMARY" | sed "s/'/''/g")

docker exec -i homeai-postgres psql -U postgres -d homeai -tAc "
INSERT INTO model_usage_history
  (context_layer, tier, actor, model, provider, task_summary,
   tokens_in, tokens_out, cost_gbp)
VALUES
  ('build', '$TIER', 'claude_code', '$MODEL', '$PROVIDER',
   '$SUMMARY_ESC', $TOK_IN, $TOK_OUT, $COST)
RETURNING id;" >/dev/null

echo "✓ logged: [$TIER] $MODEL — $SUMMARY (£$COST)"
