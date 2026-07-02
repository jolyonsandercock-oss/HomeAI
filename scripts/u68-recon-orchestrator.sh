#!/usr/bin/env bash
#
# u68-recon-orchestrator.sh — runs L1, L2, L3 in sequence + sends a single
# Telegram summary. This is the script wrapped by the n8n RECON-NIGHTLY
# workflow per SPEC §4b.8 Phase 7/8.
#
# Failure handling: each step is run with continue-on-error; the summary
# pulse always fires with status per step. A hard step failure flips the
# summary to severity=high.
#
# Usage:
#   bash u68-recon-orchestrator.sh           # default 30-day window
#   bash u68-recon-orchestrator.sh 14        # override window

set -euo pipefail   # -e added (R0.9): per-step failures are still captured via
                    # `run_step ... || STATUS[x]="fail"` (|| is -e-exempt), so the
                    # continue-on-error step design below is unaffected. The
                    # summary-count psql_q calls are separately guarded so a query
                    # failure can't abort before the Telegram pulse fires.

WINDOW="${1:-30}"
LOG_PFX="[u68-recon-orchestrator]"
TG_NOTIFY="${HOME}/.. >/dev/null"

run_step() {
    local name="$1"; shift
    local cmd="$*"
    local t0=$SECONDS
    echo "${LOG_PFX} ▶ ${name}"
    if eval "$cmd" > "/tmp/${name}.out" 2>&1; then
        printf -v _dur "%ds" $((SECONDS - t0))
        local exc=$(grep -c "INSERT 0 " "/tmp/${name}.out" || echo 0)
        echo "${LOG_PFX} ✓ ${name} (${_dur})"
        return 0
    else
        local rc=$?
        echo "${LOG_PFX} ✗ ${name} (exit $rc)"
        tail -10 "/tmp/${name}.out" >&2
        return $rc
    fi
}

declare -A STATUS
STATUS[l1]="ok"; STATUS[l2]="ok"; STATUS[l3]="ok"

run_step "l1" "bash /home_ai/scripts/u67-recon-l1.sh $WINDOW" || STATUS[l1]="fail"
run_step "l2" "bash /home_ai/scripts/u68-recon-l2.sh $WINDOW" || STATUS[l2]="fail"
run_step "l3" "bash /home_ai/scripts/u68-recon-l3.sh $WINDOW" || STATUS[l3]="fail"

# ── Summary counts ──────────────────────────────────────────────────
psql_q() {
    docker exec -i homeai-postgres psql -U postgres -d homeai -X -q -A -t -c "$1" | tr -d '[:space:]'
}

L1_TOTAL=$(psql_q "SELECT COUNT(*) FROM mart.daily_totals          WHERE transaction_date >= current_date - ${WINDOW}") || L1_TOTAL="ERR"
L1_MISMATCH=$(psql_q "SELECT COUNT(*) FROM mart.daily_totals       WHERE transaction_date >= current_date - ${WINDOW} AND status='mismatch'") || L1_MISMATCH="ERR"
L2_OPEN=$(psql_q  "SELECT COUNT(*) FROM mart.exceptions             WHERE kind LIKE 'l2_%' AND status='open'") || L2_OPEN="ERR"
L3_UNSETTLED=$(psql_q "SELECT COUNT(*) FROM mart.expected_settlements WHERE status='unsettled_5d' AND batch_date >= current_date - ${WINDOW}") || L3_UNSETTLED="ERR"
L3_SHORT=$(psql_q "SELECT COUNT(*) FROM mart.expected_settlements   WHERE status='settled_short' AND batch_date >= current_date - ${WINDOW}") || L3_SHORT="ERR"

# ── Telegram pulse ──────────────────────────────────────────────────
icon_l1=$([[ ${STATUS[l1]} == ok ]] && echo "✓" || echo "✗")
icon_l2=$([[ ${STATUS[l2]} == ok ]] && echo "✓" || echo "✗")
icon_l3=$([[ ${STATUS[l3]} == ok ]] && echo "✓" || echo "✗")

msg="<b>RECON nightly — ${WINDOW}d window</b>%0A"
msg+="${icon_l1} L1: ${L1_MISMATCH} mismatch / ${L1_TOTAL} daily rows%0A"
msg+="${icon_l2} L2: ${L2_OPEN} open exceptions (refunds / outliers)%0A"
msg+="${icon_l3} L3: ${L3_UNSETTLED} unsettled-5d, ${L3_SHORT} settled-short"

bash /home_ai/.claude/scripts/notify-telegram.sh "$msg" "u68-recon" >/dev/null || true

# Exit status: 0 if all steps ok, 1 if any failed.
if [[ ${STATUS[l1]} == ok && ${STATUS[l2]} == ok && ${STATUS[l3]} == ok ]]; then
    echo "${LOG_PFX} all green"
    exit 0
else
    echo "${LOG_PFX} step failures — see /tmp/l*.out" >&2
    exit 1
fi
