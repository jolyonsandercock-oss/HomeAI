#!/usr/bin/env bash
# u87-audit-vault-paths.sh — list every secret/* path with created/updated
# timestamps and queue a recommended rotation date.
# Read-only. Output: audits/<date>-vault-rotation-calendar.md

set -euo pipefail
OUT=/home_ai/audits/$(date +%Y-%m-%d)-vault-rotation-calendar.md

VT=$(docker inspect homeai-bot-responder --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
export VT

# Recurse the KV mount
walk() {
    local prefix="$1"
    local paths
    paths=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv list -format=json "secret/$prefix" 2>/dev/null \
            | python3 -c "import sys,json; [print(x) for x in json.load(sys.stdin)]" 2>/dev/null || true)
    for p in $paths; do
        if [[ "$p" == */ ]]; then
            walk "${prefix}${p}"
        else
            full="${prefix}${p}"
            meta=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv metadata get -format=json "secret/$full" 2>/dev/null)
            created=$(echo "$meta" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('created_time',''))" 2>/dev/null)
            updated=$(echo "$meta" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('updated_time',''))" 2>/dev/null)
            echo "$full|$created|$updated"
        fi
    done
}

walk "" > /tmp/vault-paths.tsv

{
echo "# Vault rotation calendar"
echo ""
echo "Generated $(date -Iseconds). Read-only."
echo ""
echo "Recommended rotation windows:"
echo "- 30d: API keys, OAuth tokens (\`*api*\`, \`*token*\`)"
echo "- 90d: Database passwords, admin passwords (\`*password*\`, \`*admin*\`, \`*pw*\`)"
echo "- 365d: Long-lived signing keys, HMAC keys, encryption keys (\`*key*\`, \`*hmac*\`, \`*signing*\`)"
echo ""
echo "## Sorted by age (oldest first)"
echo ""
echo "| secret/ path | created | last updated | age days | recommended window | next rotation due |"
echo "|---|---|---|---|---|---|"

while IFS='|' read -r path created updated; do
    [[ -z "$path" ]] && continue
    # Compute age
    if [[ -n "$updated" ]]; then
        u_ts=$(date -d "$updated" +%s 2>/dev/null || echo 0)
        now=$(date +%s)
        age_days=$(( (now - u_ts) / 86400 ))
    else
        age_days="?"
    fi
    # Window
    case "$path" in
        *api*|*token*|*oauth*) window=30; class="API/token";;
        *password*|*admin*|*pw*) window=90; class="password";;
        *key*|*hmac*|*signing*) window=365; class="signing key";;
        *) window=90; class="default";;
    esac
    # Due date
    if [[ "$age_days" =~ ^[0-9]+$ ]]; then
        due_in=$((window - age_days))
        if (( due_in < 0 )); then due="🔴 OVERDUE $((due_in * -1))d"
        elif (( due_in < 14 )); then due="🟡 ${due_in}d"
        else due="${due_in}d"
        fi
    else due="?"; fi
    echo "| $path | ${created:0:10} | ${updated:0:10} | $age_days | $window ($class) | $due |"
done < /tmp/vault-paths.tsv | sort -t'|' -k5 -nr

total=$(wc -l < /tmp/vault-paths.tsv)
echo ""
echo "## Summary"
echo ""
echo "- Total Vault paths tracked: $total"
echo ""
echo "_No rotation performed automatically — this is calendar-only. Use \`vault kv put\` with a new value when ready._"
unset VT
} > "$OUT"
echo "✓ wrote $OUT"
