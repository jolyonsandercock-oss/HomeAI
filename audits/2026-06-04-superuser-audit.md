# Superuser-bypass audit

Generated 2026-06-04T23:16:23+01:00. Read-only.

Scripts in /home_ai/scripts/ and /home_ai/services/ that connect as
`postgres` superuser bypass RLS by default. Each is categorised:

- `ddl-needed` — runs migrations / CREATE / ALTER. Keep on superuser.
- `should-be-pipeline` — DML only. Migrate to `homeai_pipeline` + SET LOCAL guards.
- `should-be-readonly` — SELECT only. Migrate to `homeai_readonly`.

## Script-by-script

| file | line | category | rationale |
|---|---|---|---|
