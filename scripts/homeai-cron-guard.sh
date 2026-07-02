#!/usr/bin/env bash
# homeai-cron-guard.sh — enforce joly's crontab against the committed snapshot
# (desired-state / infrastructure-as-code for cron). Runs every 5 min (systemd
# timer homeai-cron-guard.timer).
#
# WHY THE REWRITE (2026-06-15): the old version only reinstalled when the live
# job COUNT fell below 15. The real failure mode is a *partial* silent drop — on
# 29 May ~6 jobs (xero/dext/calendar/tanda/apply-feedback/rejection-digest)
# vanished while the count stayed at ~49, so it was never detected and they sat
# dead for 17 days. This version reconciles PER JOB:
#   • a job in the snapshot but MISSING from live   → restore it + Telegram
#   • a job in live but NOT in the snapshot         → Telegram only (kept, not
#       removed, so a freshly-added job isn't nuked before you commit it).
# Discipline: when you add/change/remove a cron, update scripts/crontab.snapshot.txt
# in the same commit. The snapshot is the source of truth.
set -euo pipefail
# byte-ordering for sort AND comm — without this, comm warns "not in sorted
# order" and can miscompare cron lines (they contain */%- which collate
# differently under locale-aware sort vs comm's expectation).
export LC_ALL=C
SNAP=/home_ai/scripts/crontab.snapshot.txt
[ -f "$SNAP" ] || exit 0

# normalise: drop comments/blanks, collapse whitespace, trim, sort-unique
norm() { grep -vE '^\s*#|^\s*$' "$1" 2>/dev/null | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | sort -u; }

live_raw=$(mktemp); snap_n=$(mktemp); live_n=$(mktemp)
crontab -u joly -l 2>/dev/null > "$live_raw"
norm "$SNAP"      > "$snap_n"
norm "$live_raw"  > "$live_n"

missing=$(comm -23 "$snap_n" "$live_n")   # in snapshot, not live  → restore
extra=$(comm -13 "$snap_n" "$live_n")     # in live, not snapshot  → alert only

alert() { bash /home_ai/.claude/scripts/notify-telegram.sh "$1" "cron-guard" >/dev/null 2>&1 || true; }
audit() { docker exec -i homeai-postgres psql -U postgres -d homeai \
  -c "INSERT INTO audit_log(pipeline,action,ai_parsed) VALUES('cron-guard','self_repair',jsonb_build_object('repair','$1','detail',\$j\$$2\$j\$));" \
  >/dev/null 2>&1 || true; }

if [ -n "$missing" ]; then
  n=$(printf '%s\n' "$missing" | grep -c . || true)
  # restore by appending the snapshot's missing lines to the live crontab
  # (preserves any legitimate extras; idempotent — next run they're present)
  { cat "$live_raw"; printf '%s\n' "$missing"; } | crontab -u joly -
  audit restore_missing_cron "$missing"
  alert "🛠 cron-guard restored $n missing cron job(s) from snapshot:
$missing"
fi

if [ -n "$extra" ]; then
  n=$(printf '%s\n' "$extra" | grep -c . || true)
  alert "⚠️ cron-guard: $n cron job(s) running but NOT in the snapshot — commit them to scripts/crontab.snapshot.txt so they're protected:
$extra"
fi

rm -f "$live_raw" "$snap_n" "$live_n"
