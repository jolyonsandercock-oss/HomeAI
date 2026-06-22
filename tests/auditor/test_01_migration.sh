#!/bin/bash
set -euo pipefail
PSQL="docker exec homeai-postgres psql -U postgres -d homeai -tAc"
cols=$($PSQL "select string_agg(column_name,',' order by column_name) from information_schema.columns where table_schema='cognition' and table_name='agent_findings' and column_name in ('severity','status','fingerprint','last_seen_at')")
[ "$cols" = "fingerprint,last_seen_at,severity,status" ] || { echo "FAIL: missing cols, got [$cols]"; exit 1; }
echo PASS
