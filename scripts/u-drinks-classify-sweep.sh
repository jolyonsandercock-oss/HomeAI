#!/usr/bin/env bash
# u-drinks-classify-sweep.sh — deterministic beer/wine/spirits/minerals classifier.
# Applies drinks_category_rules to vendor_invoice_lines rows with drinks_subcategory IS NULL.
# Idempotent (only fills NULLs). Unmatched drinks-supplier lines are surfaced by £ for
# rule-adding — never guessed. Records an ops.pipeline_runs heartbeat.
# Cron suggestion: 50 7 * * *  (after the line sweep at 07:40).
set -euo pipefail
VT=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
PW=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=password secret/postgres 2>/dev/null)
psqlc(){ docker exec -i -e PGPASSWORD="$PW" homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 "$@"; }

N=$(psqlc -tAq <<'SQL' | grep -E '^[0-9]+$' | tail -1
SET app.current_entity='all'; SET app.current_realm='owner';
WITH upd AS (
  UPDATE vendor_invoice_lines l
  SET drinks_subcategory = (
    SELECT r.subcategory FROM drinks_category_rules r
    WHERE r.active AND l.description ~* r.pattern
    ORDER BY r.priority ASC, length(r.pattern) DESC LIMIT 1)
  WHERE l.drinks_subcategory IS NULL
    AND EXISTS (SELECT 1 FROM drinks_category_rules r WHERE r.active AND l.description ~* r.pattern)
  RETURNING 1)
SELECT count(*) FROM upd;
SQL
)
echo "drinks-classify: classified $N newly-matched line(s)"
echo "OPS_ROWS=$N"

# surface-don't-guess: top unclassified lines from drinks suppliers (St Austell etc.), by £
echo "── Unclassified drinks-supplier lines (add a rule):"
psqlc -tA -F'  ' <<'SQL' || true
SET app.current_entity='all'; SET app.current_realm='owner';
SELECT round(sum(l.line_net),2) AS gbp, count(*) n, left(l.description,46) AS sample
FROM vendor_invoice_lines l JOIN vendor_invoice_inbox v ON v.id=l.invoice_id
WHERE l.drinks_subcategory IS NULL
  AND v.vendor_domain ~* '(staustell|brewery|matthew clark|ldf|drink|wine|molson|heineken)'
GROUP BY left(l.description,46)
HAVING sum(l.line_net) > 20
ORDER BY 1 DESC LIMIT 12;
SQL

# heartbeat (registry FK: register first if absent)
psqlc -tA >/dev/null <<SQL
SET app.current_entity='all'; SET app.current_realm='owner';
INSERT INTO ops.pipeline_registry(name,kind,script_path,schedule_cron,target_rel,freshness_sql,freshness_sla_hours,notes)
VALUES('drinks_classify','classify','scripts/u-drinks-classify-sweep.sh','50 7 * * *','vendor_invoice_lines',
       'SELECT max(created_at) FROM vendor_invoice_lines',48,'beer/wine/spirits/minerals line classifier')
ON CONFLICT(name) DO NOTHING;
SELECT ops.record_pipeline_run('drinks_classify','ok',now(),$N,'deterministic drinks rules');
SQL
