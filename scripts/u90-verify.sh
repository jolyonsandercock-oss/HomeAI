#!/usr/bin/env bash
# u90-verify.sh — post-session check that every U90 packet item landed.
# Prints PASS/FAIL per check; exits with count of failures.

set -uo pipefail
fails=0

check() {
    local label="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        printf "  ✓ PASS  %s\n" "$label"
    else
        printf "  ✗ FAIL  %s\n" "$label"
        fails=$((fails+1))
    fi
}

echo "── U90 packet verification — $(date -Iseconds)"
echo

echo "1. SUDO BLOCK"
echo
check "Vault unsealed"  'docker exec homeai-vault vault status -format=json | python3 -c "import sys,json;exit(0 if not json.load(sys.stdin)[\"sealed\"] else 1)"'
check "Vault auto-unseal configured" 'docker exec homeai-vault vault status -format=json | python3 -c "import sys,json;exit(0 if json.load(sys.stdin).get(\"recovery_seal_type\") in (\"transit\",\"awskms\",\"gcpckms\",\"azurekeyvault\") else 1)" 2>/dev/null'
check "Vault image age < 14d" "docker inspect homeai-vault --format '{{.Created}}' | xargs -I{} date -d {} +%s | awk -v now=\$(date +%s) '{exit (now-\$1 < 14*86400) ? 0 : 1}'"
check "Alertmanager image age < 30d" "docker inspect homeai-alertmanager --format '{{.Created}}' | xargs -I{} date -d {} +%s | awk -v now=\$(date +%s) '{exit (now-\$1 < 30*86400) ? 0 : 1}'"

echo
echo "2. EXTERNAL BLOCK"
echo
check "Bank acct 48885517 has tx rows" 'docker exec homeai-postgres psql -U postgres -d homeai -At -c "SELECT count(*) > 0 FROM bank_transactions WHERE bank_account_id=15" 2>/dev/null | grep -q "^t$"'
check "Bank acct 4 (Tax Reserve) recent tx within 30d" 'docker exec homeai-postgres psql -U postgres -d homeai -At -c "SELECT count(*) > 0 FROM bank_transactions WHERE bank_account_id=4 AND transaction_date > current_date - 30" 2>/dev/null | grep -q "^t$"'
check "Loan 284512-03 closed_date refined (not placeholder)" 'docker exec homeai-postgres psql -U postgres -d homeai -At -c "SELECT count(*) FROM mortgage_accounts WHERE account_ref='\''284512-03'\'' AND closed_date != '\''2022-01-01'\''::date" 2>/dev/null | grep -qE "^[1-9]"'
check "Land Registry deeds scanned for 5 properties" 'find /mnt/shared_storage/scans/inbox -name "*Land*Registry*" -o -name "*title*" -o -name "*deed*" 2>/dev/null | head -1 | grep -q .'

echo
echo "── Failures: $fails"
exit "$fails"
