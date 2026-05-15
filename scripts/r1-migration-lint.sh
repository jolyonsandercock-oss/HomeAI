#!/bin/bash
# /home_ai/scripts/r1-migration-lint.sh
#
# Realm-split lint (R1, V64). Fails non-zero if any home_ai domain table in
# public.* lacks a `realm` column. Framework-exempt tables (n8n, Open WebUI,
# model-evaluator) are listed below and not required to carry realm.
#
# Wire this into:
#   - pre-deploy gate (call before `docker exec ... psql -f V<n>.sql`)
#   - selftest.sh
#   - CI / pre-push hook
#
# Exit codes:
#   0 — every non-exempt table has realm
#   1 — one or more tables are missing realm (printed to stderr)
#   2 — Postgres not reachable

set -euo pipefail

PG_CONTAINER="${PG_CONTAINER:-homeai-postgres}"
PG_DB="${PG_DB:-homeai}"
PG_USER="${PG_USER:-postgres}"

if ! docker exec "$PG_CONTAINER" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
    echo "✗ Postgres ($PG_CONTAINER) not reachable" >&2
    exit 2
fi

# Framework-exempt tables (kept in sync with V64). When a new third-party tool
# adds tables to the public schema, add them here.
EXEMPT_SQL=$(cat <<'EOF'
SELECT unnest(ARRAY[
    -- n8n framework
    'ai_builder_temporary_workflow','annotation_tag_entity','auth_identity',
    'auth_provider_sync_history','binary_data','chat_hub_agent_tools',
    'chat_hub_agents','chat_hub_messages','chat_hub_session_tools',
    'chat_hub_sessions','chat_hub_tools','command_log','credential_dependency',
    'credentials_entity','data_table','data_table_column','deployment_key',
    'diagnostic_history','dynamic_credential_entry','dynamic_credential_resolver',
    'dynamic_credential_user_entry','event_destinations','event_idempotency_keys',
    'execution_annotation_tags','execution_annotations','execution_data',
    'execution_entity','execution_metadata','folder','folder_tag',
    'insights_by_period','insights_metadata','insights_raw','installed_nodes',
    'installed_packages','instance_ai_iteration_logs','instance_ai_messages',
    'instance_ai_observational_memory','instance_ai_resources',
    'instance_ai_run_snapshots','instance_ai_threads','instance_ai_workflow_snapshots',
    'instance_version_history','invalid_auth_token','migrations',
    'oauth_access_tokens','oauth_authorization_codes','oauth_clients',
    'oauth_refresh_tokens','oauth_user_consents','processed_data','project',
    'project_relation','project_secrets_provider_access','role',
    'role_mapping_rule','role_mapping_rule_project','role_scope','scope',
    'secrets_provider_connection','settings','shared_credentials',
    'shared_workflow','tag_entity','test_case_execution','test_run',
    'token_exchange_jti','trusted_key','trusted_key_source','user',
    'user_api_keys','user_favorites','variables','webhook_entity',
    'workflow_builder_session','workflow_dependency','workflow_entity',
    'workflow_history','workflow_publish_history','workflow_published_version',
    'workflow_statistics','workflows_tags',
    -- model-evaluator / OWUI / LiteLLM
    'benchmark_results','model_recommendations','model_registry',
    'model_scan_log','model_scores','model_usage_history'
])
EOF
)

QUERY=$(cat <<EOF
WITH framework_exempt AS ($EXEMPT_SQL AS table_name)
SELECT c.relname
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public'
   AND c.relkind = 'r'
   AND c.relname NOT IN (SELECT table_name FROM framework_exempt)
   AND NOT EXISTS (
       SELECT 1 FROM information_schema.columns col
        WHERE col.table_schema = 'public'
          AND col.table_name = c.relname
          AND col.column_name = 'realm'
   )
 ORDER BY c.relname;
EOF
)

MISSING=$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tA -c "$QUERY")

if [[ -n "$MISSING" ]]; then
    echo "✗ R1 lint FAIL: the following home_ai domain table(s) are missing the realm column:" >&2
    echo "$MISSING" | sed 's/^/    /' >&2
    echo >&2
    echo "Fix: add a realm column to each table (see SPEC §2.5 and /home_ai/postgres/migrations/V64__realm_column.sql for the pattern)," >&2
    echo "or add the table to the framework-exempt list in BOTH V64 and this script if it belongs to a third-party tool." >&2
    exit 1
fi

# Count what we did cover, for a clean success message.
COVERED=$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tA -c \
    "SELECT COUNT(*) FROM information_schema.columns WHERE column_name='realm' AND table_schema='public';")

echo "✓ R1 lint PASS: $COVERED home_ai domain table(s) carry the realm column."
exit 0
