# Decision — revert the broken superuser→service-role migration (2026-06-05)

## Context
A parallel session committed `eac779b` "remove postgres superuser from compose, use
dedicated service roles" (and `f84edcc`, which despite its message only changed two
`.claude/` docs). On inspection the change was **non-functional and reboot-dangerous**:

- 7 service DSNs (postgres-exporter, build-dashboard, google-fetch, playwright,
  wa-bridge, bot-responder, + a DATABASE_URL consumer) were pointed at
  `homeai_dashboard:***`.
- The `homeai_dashboard` role **does not exist** (only `homeai_hr`, `homeai_pipeline`,
  `homeai_readonly` exist; rls-policies.sql defines no such role).
- **No Vault password** for it (`secret/postgres-roles` has only pipeline + readonly).
- The password was a **literal `***` placeholder**, not a `${VAR}` — so even creating
  the role wouldn't let services connect.
- Design smell: one shared role for all services (no least-privilege separation).

Runtime impact: **zero security benefit** (containers still ran as `postgres` superuser
because they hadn't been recreated) but **100% outage risk** — the next `start.sh`/reboot
would force-recreate against the broken DSNs and fail ~6 services. A reboot was imminent
(the parallel session had written a pre-reboot checkpoint).

## Decision
**Reverted `eac779b` in `3ad638d`.** All DSNs restored to `postgres:${POSTGRES_PASSWORD}`
(the known-good runtime state). System is reboot-safe. The parallel session was
terminated; this session is sole actor. No DB objects were created/dropped (the
"migration" never created roles), so nothing else to undo.

## The migration is still worth doing — but properly
It remains the #1 security finding (services as superuser ⇒ RLS is advisory). Correct
approach captured in `.claude/NEXT-SESSION.md` Carry-forward #1: per-service
least-privilege roles, created via migration + Vault passwords + `${VAR}` in compose,
RAG tables (`email_rag_chunks`, `search_vectors`) granted to the writer role, tested
one service at a time. Do it in a single coordinated session, never half-committed.

## Lesson
Two agents committing to one repo (as the same git identity) caused this. Commit
messages did not match diffs (`f84edcc`). Single-session discipline matters; verify
commit *contents* and live state, not commit *messages*.
