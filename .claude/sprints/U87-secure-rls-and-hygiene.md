# U87 — Secure: RLS coverage + Vault hygiene + entropy guard

**Prereqs**: U86 audits landed in `audits/2026-05-16-*.md`.

**Realm**: cross-cutting (RLS audit covers all realms; Vault rotation calendar is owner-only).

**Remote-doable**: ~85%. Vault auto-unseal + Authelia FQDN + image updates remain Jo-in-person and roll up to U90.

**Why this sprint exists**: every cron script in `/home_ai/scripts/` runs as `postgres` superuser and silently bypasses RLS — discovered in U78 when the seed-row INSERT succeeded despite `SET LOCAL` being a no-op. We need an honest map of which scripts genuinely need superuser vs which should be `homeai_pipeline`, plus a pre-commit hook for the entropy scan (currently a memory-only convention).

**Overnight-autonomous**: yes — audits + git hooks + role migration. No container restarts inside the sprint.

## Tracks

### T1 — RLS policy coverage audit (~30 min)

**Build**:
- Script `scripts/u80-audit-rls.sh`. For every table where `relrowsecurity = true`, list the policies present. Required: `entity_isolation` (PERMISSIVE) + `realm_isolation` (RESTRICTIVE). Flag any RLS-enabled table missing either.
- Also flag tables NOT enabled for RLS that contain `entity_id` or `realm` columns — likely missed by an earlier migration.
- Output: `audits/2026-05-16-rls-coverage.md`.

**Acceptance**:
- Report covers every table. Misses are listed with the exact `CREATE POLICY` statement needed.

---

### T2 — Superuser-bypass audit (~45 min)

**Build**:
- Script `scripts/u80-audit-superuser-usage.sh`. Grep `/home_ai/scripts/` + `/home_ai/services/` for `psql -U postgres` and `docker exec -u postgres`. For each match: filename, line, surrounding context.
- Categorise each into:
  - `ddl-needed` (runs migrations / DDL — keep superuser)
  - `should-be-pipeline` (DML only — migrate to `homeai_pipeline`)
  - `should-be-readonly` (SELECT only — migrate to `homeai_readonly`)
- Output: `audits/2026-05-16-superuser-audit.md` with a per-script recommendation.

**Acceptance**:
- Every script using `-U postgres` has a categorisation. Total count + per-bucket count at top.

---

### T3 — Migrate safe scripts to less-privileged roles (~90 min)

**Build**:
- For each script in T2's `should-be-readonly` bucket: change DSN to `homeai_readonly`. Smoke-test with a single dry-run invocation; if it succeeds, commit the change.
- For `should-be-pipeline`: same with `homeai_pipeline`, *but* add `SET LOCAL app.current_entity` and `SET LOCAL app.current_realm` before any INSERT/UPDATE/DELETE so RLS actually applies.
- Leave `ddl-needed` bucket on superuser; document why in a top-of-file comment.

**Acceptance**:
- All "should-be-*" scripts migrated; their next scheduled cron run completes ≥1 time before sprint commits.
- Audit re-run shows shrunk `psql -U postgres` count.

---

### T4 — Vault rotation calendar (~30 min)

**Build**:
- Script `scripts/u80-audit-vault-paths.sh`. `vault kv list -format=json secret/` recursively; for each path, `vault kv metadata get` → `created_time` / `updated_time`.
- Output: `audits/2026-05-16-vault-rotation-calendar.md` — one row per stored credential path, with "age in days" and a recommended rotation date (30d for tokens/API keys, 90d for passwords, 365d for long-lived signing keys).
- Sort by age descending.

**Acceptance**:
- Calendar lists every Vault path with age + suggested rotation date. No rotation performed automatically.

---

### T5 — Pre-commit entropy hook (~20 min)

**Build**:
- Install `.git/hooks/pre-commit` with the entropy regex from `feedback_homeai_pre_push_scan` running against staged files. Block commit on hit (non-zero exit). Allow override via `git commit --no-verify` (per AGENTS.md, only with explicit user request).
- Add `scripts/u80-install-hooks.sh` so a fresh clone re-installs it.

**Acceptance**:
- Hook runs on a synthetic test (`git add` a file containing a high-entropy token, attempt commit → blocked).

---

### T6 — Sprint-number-collision guard (~10 min)

**Build**:
- Add `scripts/next-sprint-number.sh` that prints `max(git_log_U + decisions_U + sprints_U) + 1`. AGENTS.md gets a one-liner pointer to it.
- Lesson from `feedback_check_sprint_number_first.md` (this session).

**Acceptance**:
- Script returns `U89` when run now (max = U90 from this batch + buffer of 1).

---

### T7 — Selftest expansion (~60 min)

**Build**:
- `scripts/selftest.sh` currently tests 51/52 named items per AGENTS.md. Expand to cover:
  - Every running container has a `/healthz`-style endpoint responding 200 (or skip with reason).
  - Every "critical view" returns ≥1 row over its expected window (list TBD in T1's audit output).
  - Every cron-installed script has a non-failing run in the last (24h / week / month — per its frequency).
- Output expected: 51 + N new tests. Existing pre-existing-fail unchanged.

**Acceptance**:
- `selftest.sh` runs; new tests pass or skip cleanly. Failures linked to U88 follow-ons.

---

### T8 — Commit (~5 min)

**Build**:
- Stage audits + scripts + hooks. Single commit `U87: secure — RLS coverage + role migration + rotation calendar + entropy hook`.

**Acceptance**:
- Working tree clean. Audit/INDEX.md updated.

## What this sprint does NOT do

- Does **not** run Vault auto-unseal bootstrap (Jo-in-person, U90).
- Does **not** force-enable RLS on superuser (`ALTER TABLE … FORCE ROW LEVEL SECURITY`) — risky overnight, parked for review post-U87.
- Does **not** rotate any Vault paths (only audits ages, queues rotations).
- Does **not** wire Authelia forward_auth (needs Tailscale cert FQDN, U90).

## Follow-on sprints

- **U88 — Fix and forget**: takes T2's `should-be-pipeline` bucket items that needed deeper refactor.
- **U90 — In-person packet**: queues image refresh, Vault auto-unseal, Authelia FQDN.
