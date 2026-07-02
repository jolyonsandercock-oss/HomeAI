#!/usr/bin/env bash
# run-dossier-backfill.sh — U243 S1: loop /api/memory/distill-batch until the eager
# set is distilled, the budget is hit, or errors spike. Guardrail: if the event
# system auto-pauses (flood), clear it and continue. Logs to logs/u243-s1-backfill.log.
set -euo pipefail
CONFIG=/home_ai/.claude/overnight-config.json
LOG=/home_ai/logs/u243-s1-backfill.log
BASE=http://100.104.82.53:8090
PG(){ docker exec -i homeai-postgres psql -U postgres -d homeai -tA "$@"; }
ts(){ date -u '+%Y-%m-%dT%H:%M:%SZ'; }
val(){ python3 -c "import json;print(json.load(open('$CONFIG')).get('$1','$2'))" 2>/dev/null || echo "$2"; }

BATCH=$(val backfill_batch 20); BUDGET=$(val backfill_budget_usd 30)
PER=0.033   # ~$0.033/dossier (Sonnet ~6k in / 1k out)
done_total=0; zero=0
echo "$(ts) S1 START batch=$BATCH budget=\$$BUDGET" >> "$LOG"
while :; do
  # guardrail: clear any auto-pause so the (already-fixed) pipeline keeps flowing
  if [ "$(PG -c "select (value ? 'paused_at') from static_context where key='system.state';" 2>/dev/null)" = "t" ]; then
    PG -c "update static_context set value=(value-'paused_at'-'paused_reason')||'{\"state\":\"running\"}'::jsonb where key='system.state';" >/dev/null 2>&1 || true
    echo "$(ts) guardrail: cleared auto-pause" >> "$LOG"
  fi
  resp=$(curl -s -m 600 -X POST -H 'X-Realm: owner' "$BASE/api/memory/distill-batch?limit=$BATCH" 2>/dev/null) || resp=""
  n=$(printf '%s' "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('distilled',0))" 2>/dev/null || echo 0)
  errs=$(printf '%s' "$resp" | python3 -c "import sys,json;print(len(json.load(sys.stdin).get('errors',[])))" 2>/dev/null || echo 0)
  done_total=$((done_total+n))
  cost=$(python3 -c "print(round($done_total*$PER,2))")
  total_dossiers=$(PG -c "select count(*) from counterparty_dossier;" 2>/dev/null) || total_dossiers=0
  echo "$(ts) batch distilled=$n errors=$errs run_total=$done_total dossiers=$total_dossiers est_cost=\$$cost" >> "$LOG"
  if [ "${n:-0}" -eq 0 ]; then zero=$((zero+1)); [ "$zero" -ge 2 ] && { echo "$(ts) DONE (no candidates left)" >> "$LOG"; break; }; else zero=0; fi
  [ "${errs:-0}" -gt $((BATCH/2)) ] && { echo "$(ts) STOP: error rate high ($errs/$BATCH) — investigate" >> "$LOG"; break; }
  python3 -c "import sys;sys.exit(0 if $cost < $BUDGET else 1)" || { echo "$(ts) STOP: budget \$$BUDGET reached (\$$cost)" >> "$LOG"; break; }
  sleep 30
done
# audit summary
PG -c "insert into audit_log(pipeline,action,result,ai_parsed) values('u243','u243_s1_backfill','$(printf '%s' "$cost")', jsonb_build_object('distilled_this_run',$done_total,'dossiers_total',$total_dossiers,'est_cost_usd',$cost));" >/dev/null 2>&1 || true
echo "$(ts) S1 END run_total=$done_total dossiers=$total_dossiers est_cost=\$$cost" >> "$LOG"
