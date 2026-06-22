#!/usr/bin/env bash
# u-revenue-recon-check.sh — flags any month where head_office revenue DRIFTS from the owner's
# authoritative figure (ops.revenue_truth). The ONLY revenue validation that matters (per the
# May-31 forensic: per-till is contaminated, head_office is truth, owner's report is ground truth).
# Add a month's figure: SELECT ops.set_revenue_truth('2026-06-01', <amount>, 'Jo Jun report');
set -uo pipefail
VT=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
PW=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=password secret/postgres 2>/dev/null)
psqlc(){ docker exec -i -e PGPASSWORD="$PW" homeai-postgres psql -U postgres -d homeai -tAq "$@"; }
DRIFT=$(psqlc -c "SELECT string_agg(month::text||': head_office £'||head_office_total||' vs reported £'||reported_net||' (Δ£'||variance||')', E'\n') FROM ops.v_revenue_reconciliation WHERE status='DRIFT';")
N=$(psqlc -c "SELECT count(*) FROM ops.v_revenue_reconciliation WHERE status='DRIFT';")
if [ "${N:-0}" -gt 0 ]; then
  echo "REVENUE DRIFT ($N month(s)):"; echo "$DRIFT"
  bash /home_ai/.claude/scripts/notify-telegram.sh "⚠️ Revenue reconciliation DRIFT ($N month):"$'\n'"$DRIFT" "finance" >/dev/null 2>&1 || true
else
  echo "revenue reconciliation: all reconciled"
fi
psqlc -c "INSERT INTO ops.pipeline_registry(name,kind,script_path,schedule_cron,target_rel,freshness_sql,freshness_sla_hours,notes) VALUES('revenue_recon','check','scripts/u-revenue-recon-check.sh','40 8 * * *','ops.revenue_truth','SELECT now()',26,'head_office vs owner monthly figure') ON CONFLICT(name) DO NOTHING; SELECT ops.record_pipeline_run('revenue_recon','ok',now(),${N:-0},'drift months=${N}');" >/dev/null 2>&1
