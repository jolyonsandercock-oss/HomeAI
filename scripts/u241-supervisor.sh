#!/usr/bin/env bash
# u241-supervisor.sh — self-healing supervisor (U240 P1).
#
# Runs the selftest; on failure attempts SAFE, idempotent, circuit-broken
# auto-repairs, re-checks, then pages (flap-protected via notify-telegram).
# Every repair is written to audit_log so the system explains itself.
#
# DURABILITY: this should run as a systemd timer (see u241-supervisor.timer);
# cron is the interim until that's installed (cron gets wiped — that's the
# whole reason this exists).
set -uo pipefail
LOG=/home_ai/logs/u241-supervisor.log
ts(){ date -u +%FT%TZ; }
q(){ docker exec -i homeai-postgres psql -U postgres -d homeai -tAc "$1" 2>/dev/null; }
audit(){ docker exec -i homeai-postgres psql -U postgres -d homeai \
  -c "INSERT INTO audit_log(action,source,payload) VALUES('self_repair','u241-supervisor',jsonb_build_object('repair','$1','detail','$2'));" >/dev/null 2>&1; }
# circuit breaker: how many times this repair fired in the last hour
repair_count_1h(){ q "SELECT count(*) FROM audit_log WHERE action='self_repair' AND source='u241-supervisor' AND payload->>'repair'='$1' AND created_at>now()-interval '1 hour'"; }

repaired=(); skipped=()

OUT=$(bash /home_ai/scripts/selftest.sh 2>&1); RC=$?
if [ "$RC" -eq 0 ]; then echo "$(ts) selftest OK" >> "$LOG"; exit 0; fi
FAILS=$(printf '%s\n' "$OUT" | sed -n '/^FAILURES:/,$p' | grep -E '^\s*- ' || true)

# ── SAFE auto-repairs (conservative, idempotent, circuit-broken) ──
# A) paused + flood contained (no new dead-letters 30m) -> resume. Cap 2/hr.
if printf '%s' "$FAILS" | grep -q 'system.state'; then
  newdl=$(q "SELECT count(*) FROM dead_letter WHERE resolved=false AND created_at>now()-interval '30 min'")
  n=$(repair_count_1h resume_contained_pause); n=${n:-0}
  if [ "${newdl:-1}" -eq 0 ] && [ "$n" -lt 2 ]; then
    q "UPDATE static_context SET value=jsonb_set(value,'{state}','\"running\"'), updated_at=now() WHERE key='system.state'" >/dev/null
    audit resume_contained_pause "no_new_dl_30m"; repaired+=("resumed paused system (flood contained)")
  else
    skipped+=("PAUSE not auto-resumed (new DL=${newdl:-?} / fired ${n:-?}x/hr) — needs eyes")
  fi
fi
# B) stuck processing leases -> recover_stale_leases_v3()
if printf '%s' "$FAILS" | grep -q 'stuck processing'; then
  q "SELECT recover_stale_leases_v3()" >/dev/null; audit recover_leases ""; repaired+=("recovered stale leases")
fi
# C) missing month partition -> selftest names it; create current+next defensively
if printf '%s' "$FAILS" | grep -qiE 'partition'; then
  q "SELECT create_events_partition(date_trunc('month',now())::date); SELECT create_events_partition(date_trunc('month',now()+interval '1 month')::date)" >/dev/null 2>&1 \
    && { audit create_partition ""; repaired+=("created event partition(s)"); }
fi
# D) email reprocess backlog (noOp-skip) -> close-sweep
if printf '%s' "$FAILS" | grep -qiE 'pending|backlog'; then
  bash /home_ai/scripts/u239-event-close-sweep.sh >/dev/null 2>&1 && { audit close_sweep ""; repaired+=("ran event close-sweep"); }
fi

# ── re-check after repairs ──
bash /home_ai/scripts/selftest.sh >/dev/null 2>&1; RC2=$?

# ── page (notify-telegram dedupes flapping by source) ──
state=$([ "$RC2" -eq 0 ] && echo "RECOVERED ✅" || echo "STILL FAILING ❗ — needs you")
msg="🩺 SUPERVISOR · selftest FAILED
Failures:
${FAILS:-  (see log)}
Auto-repaired: ${repaired[*]:-none}${skipped:+
Held: ${skipped[*]}}
After repair: $state"
bash /home_ai/.claude/scripts/notify-telegram.sh "$msg" "supervisor" >/dev/null 2>&1 || true
# (P1 follow-up: also send via the email channel + ping the hosted dead-man's switch)
echo "$(ts) FAIL rc=$RC repaired=[${repaired[*]:-}] held=[${skipped[*]:-}] after=$RC2" >> "$LOG"
[ "$RC2" -eq 0 ] && exit 0 || exit 1
