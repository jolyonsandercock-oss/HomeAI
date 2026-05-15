#!/usr/bin/env bash
# u71-pipeline-role-smoke.sh — log in as homeai_pipeline and run a
# representative slice of build-dashboard / bot-responder / critical-listener
# queries. Outputs which (if any) tables/views still need grants.
#
# Read-only; safe to run on production.

set -uo pipefail

VAULT_TOKEN=$(docker inspect homeai-bot-responder \
  --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep '^VAULT_TOKEN=' | cut -d= -f2-)

PW=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault \
     vault kv get -field=homeai_pipeline secret/postgres-roles)

run() {
    local label="$1" sql="$2"
    out=$(PGPASSWORD="$PW" docker exec -e PGPASSWORD="$PW" \
          homeai-postgres psql -U homeai_pipeline -d homeai -At -c "$sql" 2>&1)
    if [[ $? -eq 0 && -n "$out" ]]; then
        printf "  ✓ %-40s → %s\n" "$label" "$(echo "$out" | head -1 | head -c 60)"
    elif [[ $? -eq 0 ]]; then
        printf "  ✓ %-40s → (empty)\n" "$label"
    else
        printf "  ✗ %-40s → %s\n" "$label" "$(echo "$out" | head -1 | head -c 90)"
    fi
}

echo "U71 T4 — homeai_pipeline role read smoke"
echo

run "public.bot_instructions count"     "SELECT count(*) FROM bot_instructions"
run "public.children count"              "SELECT count(*) FROM children"
run "public.documents count"             "SELECT count(*) FROM documents"
run "public.vendor_invoice_inbox count"  "SELECT count(*) FROM vendor_invoice_inbox"
run "public.till_reconciliation count"   "SELECT count(*) FROM till_reconciliation"
run "public.system_state ocr.engine"     "SELECT value FROM system_state WHERE key='ocr.engine'"
run "public.recipes count"               "SELECT count(*) FROM recipes"
run "mart.exceptions count"              "SELECT count(*) FROM mart.exceptions"
run "mart.cash_variance count (1mo)"     "SELECT count(*) FROM mart.cash_variance WHERE transaction_date >= current_date - 30"
run "raw.touchoffice_orders count"       "SELECT count(*) FROM raw.touchoffice_orders"
run "staging.payments count"             "SELECT count(*) FROM staging.payments"
run "public.touchoffice_plu_sales count" "SELECT count(*) FROM touchoffice_plu_sales"
run "public.manager_notes count"         "SELECT count(*) FROM manager_notes"
run "public.bank_transactions count"     "SELECT count(*) FROM bank_transactions"
run "set_config app.current_realm"       "SELECT set_config('app.current_realm','work',false)"
run "home_ai.set_realm helper"           "SELECT home_ai.set_realm('work')"

unset PW VAULT_TOKEN
