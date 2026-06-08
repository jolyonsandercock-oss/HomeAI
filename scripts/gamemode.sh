#!/usr/bin/env bash
# gamemode.sh — free the GPU for gaming, safely, and put it all back + TEST.
#
#   gamemode.sh pause    pause pipelines (kill switch) + stop Ollama → frees VRAM
#   gamemode.sh resume   restart Ollama + unpause + recover backlog + self-test
#   gamemode.sh status   show current state
#
# Why the kill switch: while system.state=paused, u241-supervisor leaves Ollama
# down and does NOT page (Repair E guard) — so it won't fight your game. resume
# re-drives any email classifications that failed/queued while you were away and
# runs the full self-test to confirm a clean return.
set -uo pipefail

OLLAMA=homeai-ollama
PGc(){ docker exec -i homeai-postgres psql -U postgres -d homeai -tAc "$1" 2>/dev/null; }
ts(){ date '+%H:%M:%S'; }
gpu(){ nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null | tr -d ' ' || echo "n/a"; }

pause_mode(){
  echo "[$(ts)] GPU before : $(gpu)"
  PGc "UPDATE static_context
          SET value = jsonb_build_object('state','paused','paused_at',now()::text,
                       'paused_reason','manual: gaming (gamemode.sh)'),
              updated_at = now()
        WHERE key='system.state'" >/dev/null
  echo "[$(ts)] kill switch -> PAUSED (supervisor will leave Ollama down + not page)"
  echo "[$(ts)] letting in-flight work settle (15s)..."; sleep 15
  if docker stop "$OLLAMA" >/dev/null 2>&1; then echo "[$(ts)] Ollama stopped — card freed"
  else echo "[$(ts)] Ollama was already stopped"; fi
  sleep 3
  echo "[$(ts)] GPU after  : $(gpu)"
  echo "▸ Game on. Run:  gamemode.sh resume   when you're done."
}

resume_mode(){
  echo "[$(ts)] GPU before : $(gpu)"
  docker start "$OLLAMA" >/dev/null 2>&1 || (cd /home_ai && docker compose up -d ollama) >/dev/null 2>&1
  echo "[$(ts)] Ollama starting..."
  ok=0; for i in $(seq 1 20); do docker exec "$OLLAMA" ollama list >/dev/null 2>&1 && { ok=1; break; }; sleep 3; done
  [ "$ok" = 1 ] || { echo "[$(ts)] ✗ Ollama did NOT come up — aborting (system left PAUSED)"; exit 1; }
  echo "[$(ts)] Ollama up — warming + testing the classify model..."
  reply=$(timeout 90 docker exec "$OLLAMA" ollama run qwen2.5:7b "reply with one word: ok" 2>/dev/null | tr -d '\r\n' | head -c 60)
  echo "[$(ts)]   model replied: '${reply:-<none>}'"
  [ -n "${reply:-}" ] || { echo "[$(ts)] ✗ model did not respond — aborting (system left PAUSED)"; exit 1; }

  PGc "UPDATE static_context
          SET value='{\"state\":\"running\",\"paused_at\":null,\"paused_reason\":null}'::jsonb,
              updated_at=now()
        WHERE key='system.state'" >/dev/null
  echo "[$(ts)] kill switch -> RUNNING (pipelines resumed)"

  redrove=$(PGc "WITH s AS (
      SELECT e2.id FROM events e2
        LEFT JOIN emails em ON em.gmail_message_id = e2.payload->>'gmail_message_id'
       WHERE e2.event_type='email.received' AND e2.status IN ('failed','processing')
         AND em.gmail_message_id IS NULL AND e2.created_at > now()-interval '12 hours')
    UPDATE events e SET status='pending', processing_started_at=NULL,
           processing_node_id=NULL, retry_count=0
      FROM s WHERE e.id=s.id RETURNING e.id" | grep -c . || true)
  echo "[$(ts)] re-drove ${redrove:-0} queued/failed email event(s) for reclassification"

  echo "[$(ts)] running full self-test..."
  out=$(bash /home_ai/scripts/selftest.sh 2>&1)
  echo "$out" | grep -E '\[FAIL\]' || true
  echo "$out" | grep -E '── summary|PASS:|WARN:|FAIL:'
  echo "[$(ts)] GPU after  : $(gpu)"
  if echo "$out" | grep -qE 'FAIL: +0'; then echo "▸ ✅ Resumed clean — all green."
  else echo "▸ ⚠️  Resumed, but the self-test has failures (above) — check before relying on it."; fi
}

status_mode(){
  echo "kill switch : $(PGc "SELECT value FROM static_context WHERE key='system.state'")"
  echo "ollama      : $(docker ps -a --format '{{.Names}} {{.Status}}' | grep "$OLLAMA" || echo 'not found')"
  echo "GPU mem     : $(gpu)"
}

case "${1:-}" in
  pause|on)    pause_mode ;;
  resume|off)  resume_mode ;;
  status)      status_mode ;;
  *) echo "usage: $(basename "$0") {pause|resume|status}"; exit 2 ;;
esac
