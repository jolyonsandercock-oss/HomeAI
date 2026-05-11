---
name: pause-all
description: Immediately pause all pipeline processing — sets system.state to paused
---

Pauses all event processing per SPEC §4.3 Global Kill Switch. Master Router
checks `static_context.system.state` on each 30s cycle and stops claiming
events when paused.

```bash
docker exec homeai-postgres psql -U postgres -d homeai -c "
  UPDATE static_context
     SET value = jsonb_build_object(
                   'state',         'paused',
                   'paused_at',     NOW()::text,
                   'paused_reason', 'manual pause via /pause-all'),
         updated_at = NOW()
   WHERE key = 'system.state'
  RETURNING value;
"
```

Verify:

```bash
docker exec homeai-postgres psql -U postgres -d homeai -c \
  "SELECT value FROM static_context WHERE key='system.state';"
# Expected: {"state":"paused", "paused_at":"...", "paused_reason":"manual pause via /pause-all"}
```

In-flight workflow runs that have already claimed events will continue —
pause stops *new* claims, not running executions.

Resume with `/resume-all` after fixing root cause.
