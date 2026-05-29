# U228 — Alerting completeness

**Realm:** work (ops hardening; WORK-only per realm split).

**Trigger:** 2026-05-28 vault unseal recovery exposed three independent alerting gaps:
1. `alert-sink-v1` writes Prometheus alerts to `system_alerts` table but does NOT call `notify-bridge-v1` — meaning every Prometheus alert except `DeadLetterFlood` (which has its own auto-pause path) has been silent since deployment.
2. `WatchdogN8nErrors` fingerprint includes a timestamp bucket → fresh `system_alerts` row every 15 min → never auto-resolves → 7 rows accumulated during the vault recovery on top of pre-existing pile.
3. `alert-sink-v1` has no path for Alertmanager "resolved" messages — once a row reaches `firing`, it stays that way until someone manually UPDATEs.

**Status:** queued.

**Why it matters:** the 19h silent vault outage on 2026-05-26 mostly came down to (1) — alerting WAS firing in Prometheus but it never reached Jo's Telegram. The host watchdog from the 2026-05-28 recovery covers vault specifically, but everything else (Postgres replication lag, ollama-down, disk pressure, etc.) is still going to `system_alerts` and dying there.

---

## T1 — Wire `alert-sink-v1` → `notify-bridge-v1`

The cleanest topology: alert-sink stays as the canonical writer to `system_alerts`, but also fans out to notify-bridge after the Upsert step.

- [ ] Read current `alert-sink-v1` workflow nodes via `workflow_history.versionId = '069a0254-...'` (per memory `feedback-n8n-workflow-history-runtime`).
- [ ] Add a new `n8n-nodes-base.httpRequest` node `Notify` between `Upsert system_alerts + audit` and `Auto-Pause?`. POSTs to `http://homeai-n8n:5678/webhook/notify-bridge` with body `{"text": "<formatted alert message>"}`.
- [ ] Format the message: emoji by severity (🔴 critical / 🟡 warning / ℹ info), alertname bolded, first line of `annotations.summary`, link to Grafana if `generatorURL` present.
- [ ] Set the new node to "Continue on fail" — notify-bridge dying must NOT block the Upsert audit or the Auto-Pause.
- [ ] Update connections (insert Notify between Upsert and Auto-Pause).
- [ ] Insert new `workflow_history` row with fresh UUID, repoint `workflow_entity.activeVersionId`.
- [ ] Use n8n API rather than direct SQL where possible (per memory same).

## T2 — Fix `WatchdogN8nErrors` fingerprint

Current fingerprint pattern: `watchdog_n8n_errors:YYYYMMDDHHMM` (per memory `feedback-watchdog-n8n-alert-accumulates`). Each 15-min tick → new row → never upserts.

- [ ] Locate the workflow `Watchdog — n8n Errors` (or wherever the fingerprint is constructed).
- [ ] Change fingerprint to either:
  - `watchdog_n8n_errors` (one open alert at a time, simplest), or
  - `watchdog_n8n_errors:<failingWorkflowId>` (one per affected workflow, more granular)
- [ ] Deploy via n8n API + repoint activeVersionId.
- [ ] Bulk-resolve any stragglers in `system_alerts` after deploy.

## T3 — Alertmanager "resolved" message handling

Alertmanager DOES send a webhook when an alert clears (`status=resolved`). The current `Flatten Alerts` step in alert-sink reads `status` but the Upsert clause doesn't act on `resolved` differently — and notify-bridge isn't called either way.

- [ ] Add a code-node branch: when `status='resolved'` and the row exists firing, UPDATE `ends_at = NOW(), status='resolved'`.
- [ ] Send a "✓ {alertname} resolved" message via notify-bridge for resolved transitions (so Jo sees recovery, not just firing).
- [ ] Don't insert new rows on resolved-with-no-existing-firing (avoid noise from out-of-order webhooks).

## T4 — Vault status on Mission Control

The vault-watchdog covers paging on transitions; the dashboard should also show steady-state status so Jo can glance.

- [ ] New slug `vault_status` returning `sealed`, `unsealed`, `down`, or `unknown` from a thin wrapper round `docker exec homeai-vault vault status` (probably a service-mode HTTP endpoint rather than docker exec from postgres).
- [ ] Tile on Mission Control (top-right next to the existing heartbeat). 🟢 unsealed / 🔴 sealed / ⚪ unknown.

## T5 — Document alerting topology

The three layers are easy to lose track of. One canonical doc, one diagram.

- [ ] `/home_ai/docs/alerting.md` covering:
  1. Prometheus rules + scrape targets (current: 4 — n8n, ollama, postgres-exporter, prometheus)
  2. Alertmanager → alert-sink-v1 (n8n webhook `prom-alert`)
  3. alert-sink → `system_alerts` + audit_log + auto-pause + Notify (new in T1)
  4. notify-bridge-v1 → Telegram (vault-dependent — see [[feedback-alerting-circular-dep]])
  5. Host vault-watchdog → Telegram direct (vault-independent fallback)
- [ ] Mermaid diagram for the data flow.

## T6 — End-to-end verification

- [ ] Manually trigger a synthetic Prometheus alert (e.g. via `amtool alert add` or a webhook curl mimicking Alertmanager).
- [ ] Confirm: `system_alerts` row, Telegram message (in <30s), audit_log entry.
- [ ] Manually resolve the alert. Confirm: row flips to `resolved`, "✓ resolved" Telegram fires, no new audit_log spam.
- [ ] Re-run after vault is sealed (drill): notify-bridge fails, watchdog still works.

---

## Deferred / out of scope

- **Add more Prometheus scrape targets** — cAdvisor, redis, blackbox probes for each service — separate U229+ work; this sprint is purely about closing the alerting *path*, not adding signal sources.
- **Second paging channel** (email-via-non-vault-SMTP) — overkill while we have the host watchdog as the vault-independent fallback. Revisit if we get a second incident class that needs paging without vault.
- **Per-user alert routing** — only Jo is on the paging list today (per memory `feedback-trusted-inbox-and-sender`); routing to Karl + Staff is its own sprint after RBAC settles.
