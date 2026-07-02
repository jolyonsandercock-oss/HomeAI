-- V280: register the daily ops digest pipeline (R0.4)
INSERT INTO ops.pipeline_registry(name,kind,script_path,schedule_cron,freshness_sql,freshness_sla_hours,notes)
VALUES ('ops_digest','report','scripts/u-ops-digest.sh','45 7 * * *',
        'SELECT max(finished_at) FROM ops.pipeline_runs WHERE name=''ops_digest'' AND status=''ok''',26,
        'R0.4 daily Telegram ops digest') ON CONFLICT (name) DO NOTHING;
