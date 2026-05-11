---
name: resume-all
description: Resume all pipeline processing after a pause — confirm root cause resolved first
---

Before resuming, confirm: the root cause of the pause has been resolved.
Check the current pause reason first:

```bash
docker exec homeai-postgres psql -U postgres -d homeai -c \
  "SELECT value FROM static_context WHERE key='system.state';"
```

If `paused_reason` starts with `auto_pause:`, an alert triggered the pause —
investigate the underlying alert in `system_alerts` before resuming:

```bash
docker exec homeai-postgres psql -U postgres -d homeai -c \
  "SELECT alertname, severity, status, summary FROM system_alerts
    WHERE status='firing' ORDER BY last_updated_at DESC LIMIT 10;"
```

Once the cause is resolved, resume:

```bash
docker exec homeai-postgres psql -U postgres -d homeai -c "
  UPDATE static_context
     SET value      = '{\"state\":\"running\",\"paused_at\":null,\"paused_reason\":null}'::jsonb,
         updated_at = NOW()
   WHERE key = 'system.state'
  RETURNING value;
"
```

Master Router picks this up on its next 30s cycle and resumes claiming events.
