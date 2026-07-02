#!/usr/bin/env bash
# u88-audit-cron.sh — for every cron-installed script, show last few exit
# codes from its log + flag scripts that haven't run successfully recently.
# Read-only. Output: audits/<date>-cron-health.md

set -euo pipefail
OUT=/home_ai/audits/$(date +%Y-%m-%d)-cron-health.md

# Pull cron schedule
cron_lines=$(crontab -l 2>/dev/null | grep -v '^#' | grep -v '^$' | grep -oE '/home_ai/scripts/[^ ]+\.sh' | sort -u || true)

{
echo "# Cron health audit"
echo ""
echo "Generated $(date -Iseconds). Read-only."
echo ""
echo "For each cron-installed script: when did its log last get written, how big is it,"
echo "and how many recent invocations produced visible errors."
echo ""
echo "| script | log file | log size | last touched | recent errors | flag |"
echo "|---|---|---|---|---|---|"

while IFS= read -r script; do
    [[ -z "$script" ]] && continue
    base=$(basename "$script" .sh)
    # Look for matching log
    log=$(ls /home_ai/logs/${base}*.log 2>/dev/null | head -1) || true
    if [[ -z "$log" ]]; then
        log="(none)"; size="—"; touched="—"; errors="—"; flag="🟡 no log"
    else
        size=$(stat -c '%s' "$log" 2>/dev/null | awk '{printf "%.1f KB", $1/1024}') || true
        touched=$(stat -c '%y' "$log" 2>/dev/null | cut -d. -f1) || true
        # Errors in last 100 lines
        errors=$(tail -100 "$log" 2>/dev/null | grep -ciE 'error|traceback|fatal|fail|exception' || true)
        # Staleness
        log_age_days=$(( ($(date +%s) - $(date -d "$touched" +%s 2>/dev/null || echo 0)) / 86400 ))
        flag=""
        if (( log_age_days > 7 )); then flag="🟡 ${log_age_days}d cold"; fi
        if (( errors > 0 )); then flag="${flag}🔴 errors"; fi
    fi
    printf "| %s | %s | %s | %s | %s | %s |\n" \
        "$(basename "$script")" "$(basename "$log" 2>/dev/null || echo "$log")" "$size" "$touched" "$errors" "$flag"
done <<< "$cron_lines"

total=$(echo "$cron_lines" | wc -l)
echo ""
echo "## Summary"
echo ""
echo "- Cron-installed scripts: $total"
echo "- Logs > 50 MB (rotate candidate): $(find /home_ai/logs -name '*.log' -size +50M 2>/dev/null | wc -l)"
echo "- Logs > 7d cold (might be dead crons): see 🟡 flags"
echo "- Logs with recent error lines: see 🔴 flags"
} > "$OUT"
echo "✓ wrote $OUT"
