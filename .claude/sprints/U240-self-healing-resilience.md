# U240 — Self-healing resilience: failure modes, detection, auto-recovery

**Realm**: cross-cutting (ops/reliability). **Risk**: medium — auto-repair must
be conservative (a system that "fixes" itself can also break itself). **Why
now**: 2026-06-04 a global auto-pause sat unnoticed for **3 days** → email
ingestion + the local model silently dead. Every layer that should have caught
it existed — and failed for the same two reasons.

## Executive finding
**We don't lack detection — we lack durable scheduling and reliable delivery.**

The two root weaknesses, proven repeatedly:
1. **Scheduling is fragile.** `selftest.sh` (which checks `system.state`, stuck
   leases, dead-letters, n8n-active, HTTP probes), `u54-pipeline-watchdog`
   (built *specifically* to page on ingest outages from OUTSIDE n8n, after the
   2026-05-13 incident), and `u165-freshness-watcher` are all **excellent — and
   none are in cron.** The host crontab keeps getting wiped (mid-May, again
   ~06-01), silently dropping the very watchdogs designed to catch this.
2. **Delivery is single-channel + dependency-coupled.** Every alert path
   (heartbeat, u54, u165, notify-bridge) is Telegram-via-Vault. If Telegram is
   down (it was) or Vault is sealed → **all alerts go dark at once.**

**The proven-robust pattern already exists**: `vault-watchdog` survived because
it's a **systemd timer** (survives crontab wipes + reboots) with **its own
vault-independent creds** + out-of-band paging. Same for `gpu-recover` (systemd
`.path` unit, auto-recovers the GPU). **The fix is to make every critical
watchdog look like vault-watchdog, and add a supervisor + redundant delivery.**

## Current resilience inventory (what we have)
| Mechanism | Type | Scheduled? | Robust? |
|---|---|---|---|
| `selftest.sh` (12+ checks incl system.state, leases, n8n-active) | script | **NO (manual)** | not wired |
| `u54-pipeline-watchdog` (out-of-n8n ingest pager) | script | **NO** | designed-but-dark |
| `u165-freshness-watcher` (data_source_freshness) | script | **NO** | dark |
| `u239-event-close-sweep` (noOp-skip stopgap) | cron | yes (added today) | crontab-fragile |
| `recover_stale_leases_v3()` | pg fn | via master-router | ok |
| `vault-watchdog` | **systemd timer** | yes | ✅ ROBUST (the model) |
| `gpu-recover` | **systemd .path** | event | ✅ ROBUST |
| Prometheus `Diag_*` alerts (system_state, dead_letter, failure_rate) | alert | yes | detection ok, **delivery dark** |
| kill switch (`system.state`) + auto-pause | guard | — | pauses but never auto-resumes/escalates |

## Failure-mode taxonomy (observed + latent)
Each: **detector · safe auto-repair · escalate-if · current gap**

| # | Failure | Detector | Auto-repair (safe) | Escalate | Gap today |
|---|---|---|---|---|---|
| A | Global auto-pause never resumed | selftest `system.state` | resume IF flood contained (no new DL 30m) | else page | selftest unscheduled; no auto-resume; delivery dark |
| B | Broken pipeline poisons event batch | pending-by-type growth | V224 skip broken type | page to fix pipeline | no detector on per-type backlog |
| C | noOp-skip (events reprocess, never marked) | processed-rate≈0 while pending↑ | u239 close-sweep | page if backlog↑ | stopgap only; root unfixed |
| D | Alert delivery dead (Telegram/Vault down) | **dead-man's switch** (no heartbeat seen) | — | out-of-band 2nd channel | ✅ DMS wired (healthchecks.io, 2026-06-05) — supervisor pings healthy/`/fail`; silence pages out-of-band. Email 2nd channel still TODO |
| E | Crontab wiped | cron-job-count < baseline | reinstall from committed snapshot | page | nothing watches the crontab |
| F | n8n restart de-registers webhook/trigger | workflow active + 0 execs in N min | reactivate + restart n8n | page | no detector |
| G | Scraper auth/CAPTCHA (Dojo/Trail/TO) | freshness stale | — (needs human re-pair) | page | u165 unscheduled |
| H | Vault sealed | vault-watchdog | auto-unseal | page | ✅ covered |
| I | GPU lost | gpu-recover .path | recover | page | ✅ covered |
| J | Container crashed | selftest service health | `docker compose up -d` | page if reflaps | selftest unscheduled |
| K | Disk full / partition missing | selftest | create next partition | page | unscheduled |
| L | Backup stale >24h | u124d | — | page | unscheduled |

## Target architecture — a self-aware supervisor
**Principle: detect continuously → diagnose → auto-repair only the *safe* set →
escalate the rest via *redundant* channels → and watch the watchers.**

1. **Everything critical becomes a systemd timer**, not a crontab line
   (survives wipes + reboots). Migrate selftest, u54, u165, u239, heartbeat,
   backup-freshness. (Crontab stays for the bulk data pipelines, but a
   `cron-guard` systemd timer reinstalls `scripts/crontab.snapshot.txt` if the
   active count drops below baseline — fixes the recurring wipe, failure E.)
2. **A supervisor** (systemd timer, every 5 min) that runs the selftest checks,
   and on each failure dispatches to an **auto-repair library** of *idempotent,
   conservative* fixes:
   - stuck leases → `recover_stale_leases_v3()`
   - active-but-idle workflow → reactivate + restart n8n
   - missing partition → create it
   - crashed container → `up -d`
   - contained pause (no new DL 30m) → resume; **uncontained pause → escalate only**
   - email reprocess backlog → run u239
   Every repair writes to `audit_log` (action, trigger, outcome) so the system
   explains itself. A repair that fails or re-fires N times → stop + escalate
   (no infinite repair loops).
3. **Redundant, dependency-light alerting.** Keep Telegram, but add a 2nd
   channel that doesn't share its failure mode (email via SMTP, and/or a hosted
   push) with creds NOT behind Vault (file-mode like `vault-watchdog` creds).
   Severity ladder: info → warn → emergency (pause/outage = emergency, both
   channels).
4. **Dead-man's switch (failure D — the one that hid this).** An *external*
   check (cheapest: a cron on a different box / a hosted uptime monitor / a
   scheduled email the supervisor must send) that pages if the supervisor's
   heartbeat stops. If the whole alerting stack is down, *silence itself* is the
   alert. Without this, "the alerter is dead" is invisible — exactly what bit us.
5. **A single health view** — `/backend` "System self-test" panel reading the
   latest supervisor run (green/amber/red per check + last auto-repair), so the
   state is visible, not just paged.

## Design guardrails (so self-healing doesn't self-harm)
- **Auto-repair only the reversible/idempotent set**; risky actions (resume an
  uncontained pause, role changes, schema) escalate, never auto-fire.
- **Rate-limit + circuit-break repairs** (max N/hour/type; after that, stop +
  page) — a flapping auto-repair is worse than the fault.
- **Every repair is audited + announced** — the system says what it did.
- **The supervisor must itself be supervised** (dead-man's switch) — turtles,
  but only two layers: supervisor + external DMS.

## Phased plan
- **P1 — Durability + visibility (highest ROI, low risk).** systemd-timer the
  existing watchdogs (selftest, u54, u165, u239, heartbeat); add `cron-guard`
  (reinstall crontab from snapshot); add the 2nd alert channel + dead-man's
  switch; add the `/backend` self-test panel. *This alone would have caught
  today's outage in 5 min.*
- **P2 — Auto-repair library.** Codify the safe repairs (leases, idle-workflow,
  partition, container, contained-pause, u239) behind the supervisor, with
  audit + circuit-breakers.
- **P3 — Coverage + runbooks.** Close remaining detectors (per-type backlog,
  webhook-dereg, backup age), write a runbook per failure mode, and fix the
  root causes the stopgaps mask (noOp-skip mark-processed; P9/Nanny 500).

## Done criteria
Kill any one component (pause, stop n8n, seal vault, wipe cron, break a webhook)
→ detected ≤5 min, auto-repaired or escalated via ≥2 channels, visible on
`/backend`, and the supervisor's own death pages out-of-band. Selftest green.
