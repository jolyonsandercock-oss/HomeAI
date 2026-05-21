# Runbook — when it breaks

Plain-English first response for the 10 most likely failure modes. Each
section has: **how you'd notice**, **first thing to try**, **deeper fixes**.

---

## 1. Dashboard won't load (302 redirect loop)

**How you'd notice**: hitting `https://jolybox.tailc27dff.ts.net/` keeps bouncing
back to the Authelia login page, even after you log in.

**First thing to try**:
```bash
# Check Authelia is up
docker ps | grep authelia       # status should be "Up X (healthy)"
docker logs homeai-authelia --tail 20
```

**Deeper**: If Authelia is restarting, the user.yaml probably has invalid YAML.
Check `security/authelia-v2/users.yaml` for indentation issues. Rollback via
`git diff security/authelia-v2/` and revert recent edits.

---

## 2. System auto-paused (DeadLetterFlood)

**How you'd notice**: events stop processing; new emails/documents don't
appear in the dashboard; selftest fails on "system.state running".

**First thing to try**:
```bash
# Confirm pause + reason
docker exec homeai-postgres psql -U postgres -d homeai -c \
  "SELECT value FROM static_context WHERE key='system.state';"

# Drain + resume (the recovery procedure from feedback_pipeline_downstream_missing)
docker exec homeai-postgres psql -U postgres -d homeai -c "
  UPDATE events SET status='failed', processed_at=NOW(),
    error_message='Drained — runbook recovery'
   WHERE status IN ('pending','processing')
     AND processing_started_at < NOW()-INTERVAL '5 minutes';
  UPDATE dead_letter SET resolved=true, resolved_at=NOW(),
    resolution_notes='Drained alongside recovery' WHERE resolved=false;
  UPDATE static_context SET
    value = jsonb_build_object('state','running','resumed_at',NOW()::text,'resumed_by','runbook'),
    updated_at = NOW() WHERE key='system.state';"
```

**Deeper**: investigate `dead_letter` rows by event_type to find the root cause.
See `feedback_pipeline_downstream_missing` + `feedback_nanny_haiku_parse_fail`
memories for the pipeline-by-pipeline pattern.

---

## 3. Telegram bot not responding

**How you'd notice**: you send a message, no reply within 60s.

**First thing to try**:
```bash
# Is the polling workflow still firing?
docker exec homeai-postgres psql -U postgres -d homeai -c "
  SELECT status, count(*) FROM execution_entity e
  JOIN workflow_entity w ON w.id=e.\"workflowId\"
  WHERE w.name='Telegram Bot (commands)'
    AND e.\"startedAt\" > NOW()-INTERVAL '5 minutes'
  GROUP BY 1;"

# DNS check from n8n container
docker exec homeai-n8n nslookup api.telegram.org
```

**Deeper**: if execution count is 0, the workflow may be deactivated. Open n8n at
`https://jolybox.tailc27dff.ts.net/n8n/` and re-enable Telegram Bot (commands).
If DNS fails, restart n8n container.

---

## 4. Dashboard 500 errors / no data

**How you'd notice**: pages render but show "no data" or HTTP 500 on slug calls.

**First thing to try**:
```bash
# Container health
docker ps | grep build-dashboard
docker logs homeai-build-dashboard --tail 30 | grep -iE "error|exception"

# Probe slug API directly
curl -H "X-Realm: owner" http://100.104.82.53:8090/api/finance/slug/today_kpis_work
```

**Deeper**: rebuild image (`main.py` is baked, not bind-mounted):
```bash
cd /home_ai
POSTGRES_PASSWORD=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault \
  vault kv get -field=password secret/postgres)
POSTGRES_PASSWORD="$POSTGRES_PASSWORD" docker compose build build-dashboard
POSTGRES_PASSWORD="$POSTGRES_PASSWORD" docker compose up -d build-dashboard
```

---

## 5. Postgres slow / queries hang

**How you'd notice**: dashboard pages take 10+ seconds to render; logs show
`statement timeout`.

**First thing to try**:
```bash
# Find long-running queries
docker exec homeai-postgres psql -U postgres -d homeai -c "
  SELECT pid, NOW()-query_start AS duration, state, query
    FROM pg_stat_activity
   WHERE state != 'idle' AND query NOT LIKE '%pg_stat_activity%'
   ORDER BY query_start LIMIT 10;"

# If stuck, terminate the slowest
docker exec homeai-postgres psql -U postgres -d homeai -c \
  "SELECT pg_terminate_backend(<pid>);"
```

**Deeper**: check disk space (`docker exec homeai-postgres df -h /var/lib/postgresql/data`).
If <10% free, the next backup will fail; vacuum + analyze critical tables.

---

## 6. Cost cap reached (P0 floor running low)

**How you'd notice**: Telegram alert from Prometheus
`P0FloorRunningLow`; calls fail with 503 from llm-router.

**First thing to try**:
```bash
# Check spend per tier
curl -H "X-Realm: work" http://100.104.82.53:8090/api/finance/slug/quota_status_7d

# Today's spend per tier
docker exec homeai-postgres psql -U postgres -d homeai -c "
  SELECT business_priority AS tier, SUM(cost_gbp)::numeric(8,4) AS spent
  FROM ai_usage
  WHERE timestamp::date = CURRENT_DATE GROUP BY 1 ORDER BY 1;"
```

**Deeper**: if a single capability_tag is burning budget, see
`audits/u148-shadow-7d.md` for tuning approach. Temporary unblock:
`UPDATE quota_allocations SET enforce_mode=false WHERE business_priority='P0';`
(reverts to shadow mode for that tier only; remember to re-enable).

---

## 7. Caterbook ingest stopped

**How you'd notice**: missing rows for today/yesterday in
`caterbook_daily_snapshots`. Telegram heartbeat may flag it.

**First thing to try**:
```bash
# Check today's run
tail /home_ai/logs/u28-caterbook.log

# Manual re-run
/home_ai/scripts/u28-caterbook-daily.sh
```

**Deeper**: if `google-fetch` is unreachable: `docker logs homeai-google-fetch`.
If OAuth token expired: re-pair via OAuth rotation script.

---

## 8. Xero CSV pull failing

**How you'd notice**: `xero-bills-YYYY-MM-DD-NOEXPORT.html` in
`data/xero-exports/`; no new rows in `xero_bills` since yesterday.

**First thing to try**: re-pair (interactive — needs you at console):
```bash
DISPLAY=:0 /home_ai/scripts/u128-xero-pair.sh
# complete 2FA in the Chromium window when it opens
# then:
DISPLAY=:0 XERO_HEADED=1 /home_ai/scripts/u128-xero-export.sh
```

**Deeper**: see `project_u128_xero` memory for the recipe. The headless cron
at 06:45 will keep failing — that's expected until OAuth2 API is built.

---

## 9. Backup didn't run

**How you'd notice**: selftest flags "nightly backup ran < 24h ago" as FAIL.

**First thing to try**:
```bash
# Last backup state
ls -la /home_ai/backups/cron.log
tail -50 /home_ai/backups/cron.log

# Manual run
/home_ai/scripts/backup-nightly.sh
```

**Deeper**: if restic complains about repository lock, `restic unlock`
on the repo (`/etc/restic/` for env). Then re-run.

---

## 10. Container OOM / disk full

**How you'd notice**: random container restarts; "Out of memory" in
`dmesg`; `docker ps` shows restarting containers.

**First thing to try**:
```bash
df -h /                                # host disk
free -h                                # host RAM
docker system df                       # docker storage
docker ps --format '{{.Names}} {{.Status}}'

# Cleanup
docker system prune -af --filter "until=24h"
```

**Deeper**: `docker stats --no-stream` to find the memory hog; if it's n8n
or ollama, restart that single container. If postgres is hot, check
`pg_stat_activity` for runaway queries (see §5).

---

## Escalation

If none of the above resolves it:

1. **Take a snapshot of state** before more changes:
   ```bash
   /home_ai/scripts/selftest.sh > /tmp/selftest-incident.log 2>&1
   docker ps --format '{{.Names}} {{.Status}}' > /tmp/containers.log
   git status > /tmp/git-state.log
   ```
2. **Telegram Jo** with what you tried + what changed: `tg_send "🚨 incident: ..."`
3. **Don't restart everything** — most issues are bounded; full restart loses transient state.

## Related memories

- `feedback_pipeline_downstream_missing` — DL flood pattern
- `feedback_nanny_haiku_parse_fail` — Nanny-specific bug
- `project_u128_xero` — Xero recipe
- `feedback_dashboard_image_rebuild` — when to rebuild vs restart
- `feedback_docker_bindmount_file_inode` — restart vs reload
