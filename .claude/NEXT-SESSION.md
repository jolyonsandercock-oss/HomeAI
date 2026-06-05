# Next session — opening context (checkpoint written 2026-06-05, pre-reboot)

## ⚠️ FIRST THING AFTER REBOOT — in this order
1. **`bash /home_ai/start.sh`** — unseal Vault + inject secrets + bring containers up.
   NEVER `docker compose up` directly.
2. **Superuser→service-role migration was REVERTED — reboot is safe.** Commit
   `eac779b` was non-functional: it pointed 7 service DSNs at `homeai_dashboard:***`
   but that role was never created, had no Vault password, and used a literal `***`
   placeholder (not a `${VAR}`). A reboot would have failed ~6 services. Reverted in
   `3ad638d` — all DSNs are back on `postgres:${POSTGRES_PASSWORD}` (the known-good
   runtime state). **Nothing to verify here; services run as superuser as before.**
   The migration is real future work (see Carry-forward) but needs doing properly,
   not as committed.
3. **Confirm the resilience watchdogs came back in cron** (crontab *should* survive
   reboot, but the recurring wipe is exactly why U240 exists):
   ```bash
   crontab -u joly -l | grep -E 'u241-supervisor|u54-pipeline|u165-freshness'   # expect 3
   ```
   If missing → `bash /home_ai/scripts/homeai-cron-guard.sh` reinstalls from
   `scripts/crontab.snapshot.txt`.
4. **Confirm the dead-man's switch is pinging** — after the first supervisor cycle
   (≤10 min) the healthchecks.io check should be green. Manual nudge:
   `bash /home_ai/scripts/u241-supervisor.sh` (pings healthy when selftest is green).

## Done this session (2026-06-05)
- **U240 P1 self-healing supervisor** (`scripts/u241-supervisor.sh`): runs selftest →
  SAFE/idempotent/circuit-broken auto-repairs (resume *contained* pause ≤2/hr,
  recover stale leases, create partitions, run u239 close-sweep) → re-checks →
  pages via Telegram (flap-deduped) → audits every repair to `audit_log`.
- **External dead-man's switch WIRED + verified** (commit `23a7cf0`): supervisor
  pings healthchecks.io each run — healthy on clean/recovered, `/fail` on a real
  unrecovered failure, **silence (box/supervisor death) trips it after the grace
  window**. Closes failure-mode D (the blind spot behind the 3-day pause).
  - URL is **file-mode**: `security/.hc-ping-url` (chmod 600, gitignored,
    vault-independent — same pattern as vault-watchdog creds). Survives a sealed Vault.
  - Known-non-critical fails (stale backup) ping **healthy** + don't page — DMS
    only fires on genuine outages.
- `scripts/homeai-cron-guard.sh` (reinstalls crontab if job count < baseline) +
  `scripts/install-resilience-systemd.sh` (promotes supervisor + cron-guard to
  systemd timers) — **written, NOT yet installed** (needs Jo's sudo).
- Selftest is **fully green** now (the stale-backup FAIL was fixed in the overnight pass).

## Jo's two manual actions (I can't do these)
1. **`sudo bash /home_ai/scripts/install-resilience-systemd.sh`** — promotes the
   supervisor + cron-guard from cron to **systemd timers** so they survive crontab
   wipes AND reboots (the root cause of the original outage). Until then they run
   from cron = the fragile thing we're fixing.
2. **healthchecks.io dashboard config**: on the check, set **Period ≈ 10 min** +
   **Grace ≈ 20 min** (match supervisor cadence) and confirm the email/notification
   channel is enabled, so two missed cycles → "down" → pages you.

## U240 P1 — remaining to finish (next session)
- **Self-hosted email alert channel** (2nd delivery path that doesn't share
  Telegram-via-Vault's failure mode) — via google-fetch `/send`, file-mode creds.
- **`/backend` self-test panel** — surface latest supervisor run (green/amber/red
  per check + last auto-repair) so health is visible, not just paged.

## Carry-forward (from the 2026-06-04 overnight session)
1. **Superuser→service-role migration — STILL THE #1 SECURITY TODO (reverted, not done).**
   The committed attempt (`eac779b`) was reverted (`3ad638d`) because it was non-functional
   (undefined `homeai_dashboard` role, no Vault password, literal `***`, and one-role-for-all
   services). Do it PROPERLY next time, in one coordinated session:
   - Per-service least privilege, not one shared role: exporter→`homeai_readonly`;
     read+write services (build-dashboard, bot-responder, google-fetch, playwright, wa-bridge)
     → a writer role with SELECT + INSERT/UPDATE only on the tables they touch + EXECUTE on the
     `home_ai.*` fns + `home_ai.set_realm`.
   - Create role(s) in a migration (mirror `postgres/rls-policies.sql`), store passwords in
     Vault `secret/postgres-roles`, reference via `${VAR}` in compose (NOT `***`), and ensure
     `start.sh` injects them.
   - Grant the new RAG tables (`email_rag_chunks`, `search_vectors`) to the writer role too,
     else `/api/research/ask` breaks under RLS.
   - Test by recreating ONE service first (`docker logs … | grep 'permission denied'`), not all.
   Audit helper: `scripts/u87-audit-superuser-usage.sh`. Review: `.claude/decisions/2026-06-04-security-review.md`.
2. **Cultural-memory follow-ups → see `.claude/sprints/U242-cultural-memory-followups.md`**
   (the resume sprint). T1 = email RAG retrieval tuning (stopwords / rarer terms / bigger
   FTS candidate set, one build-dashboard rebuild) — start there. T2 = distilled memory
   (Stage 4). T3 = backup exit-3. Invoice queries already excellent; V225–227 applied.

## U240 P3 — root causes the stopgaps still mask
- **noOp-skip mark-processed bug**: gmail-ingest doesn't mark its `email.received`
  event processed → reprocess loop. `u239-event-close-sweep` (5-min cron) is the
  stopgap; fix the producer so the sweep isn't needed.
- **P9 Report Ingestion 500 + Nanny 500**: V224 currently *skips* these event
  types in `claim_event_batch`. Once fixed, trim the V224 skip-list + replay the
  parked `document.received` events.

## Open decisions awaiting Jo (unchanged)
- O2 (distilled cultural-memory store): defaulted to "structured extraction, not a
  knowledge graph" — confirm when building Stage 4.
- Auto-load `CAPABILITIES.md` every session (852 lines) vs grep-on-demand (current).

## State at checkpoint
- Working tree **clean**, all committed. HEAD = `3ad638d` (compose revert). Latest migration V227.
- Compose DSNs on `postgres:${POSTGRES_PASSWORD}` (superuser) — reboot-safe. The broken `homeai_dashboard` migration was reverted.
- Resilience watchdogs in cron: supervisor + u54 + u165 (3). systemd layer pending Jo's sudo.
