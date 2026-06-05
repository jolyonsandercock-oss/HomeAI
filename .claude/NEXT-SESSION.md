# Next session — opening context (checkpoint written 2026-06-05, pre-reboot)

## ⚠️ FIRST THING AFTER REBOOT — in this order
1. **`bash /home_ai/start.sh`** — unseal Vault + inject secrets + bring containers up.
   NEVER `docker compose up` directly.
2. **Verify the superuser→service-role migration survived the recreate.** This is
   the #1 risk this reboot: commits `f84edcc` + `eac779b` removed the `postgres`
   superuser from compose and moved services to dedicated roles
   (`homeai_pipeline`/`homeai_readonly`). The reboot is the **first full
   force-recreate against those roles** — if grants are incomplete, services fail
   to read/write. Check:
   ```bash
   docker ps --format '{{.Names}}\t{{.Status}}' | grep homeai- | grep -iv 'up '   # any not-Up?
   bash /home_ai/scripts/selftest.sh; echo "rc=$?"                                  # expect 0 / green
   docker logs --since 5m homeai-build-dashboard 2>&1 | grep -i 'permission denied' # RLS/grant breakage
   docker logs --since 5m homeai-google-fetch  2>&1 | grep -i 'permission denied'
   ```
   If something's broken on a role grant, the fix is a targeted `GRANT` via
   `docker exec -i homeai-postgres psql -U postgres -d homeai` — not reverting to
   superuser.
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
1. **Superuser→service-role migration** — committed (`f84edcc`/`eac779b`); the
   overnight NEXT-SESSION listed it as the #1 *todo* but it was actioned after.
   **Treat as "applied, needs battle-testing"** — see post-reboot step 2.
   Audit helper: `scripts/u87-audit-superuser-usage.sh`. Security review:
   `.claude/decisions/2026-06-04-security-review.md`.
2. **Tune email RAG retrieval quality** (build-dashboard `/api/research/ask`):
   expand stopwords (account/statement/invoice/ltd…), prefer rarer terms, raise
   FTS candidate limit, rebuild. Invoice queries already excellent. (V225–227 applied.)

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
- Working tree **clean**, all committed. HEAD = `23a7cf0`. Latest migration V227.
- Resilience watchdogs in cron: supervisor + u54 + u165 (3). systemd layer pending Jo's sudo.
