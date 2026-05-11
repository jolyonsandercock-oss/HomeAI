# ADR — Dead-letter flood auto-pause via Alertmanager → n8n alert-sink

**Date:** 2026-05-08
**Status:** Accepted (live)
**Implements:** SPEC §4.6 "Dead letter flood detection: per-pipeline thresholds, Prometheus alert, n8n auto-pause, manual reactivation enforced"

## Context

SPEC §4.6 mandates that when dead-letter row count exceeds a per-hour
threshold, all pipelines must auto-pause until a human investigates.
"Manual reactivation enforced" means resume must be a deliberate human action.

Originally the watchdog-n8n-errors workflow was the only mechanism, and it
just sent a Telegram alert. No actual pause logic existed.

## Decision

Three-stage pipeline:

1. **Postgres exporter** publishes `dead_letter_count` as a gauge metric
   (V13 archived historic noise so this gauge is meaningful forward-going).
2. **Prometheus alert rule** `DeadLetterFlood` fires when
   `increase(dead_letter_count[1h]) > 10` for 5m.
3. **Alertmanager** routes the alert (and all alerts) to a single n8n
   webhook (`/webhook/prom-alert`). The `alert-sink-v1` workflow flattens
   the alert payload, UPSERTs `system_alerts`, then branches:
   - For all alerts: write `system_alerts` row + `audit_log` row.
   - For alerts in `AUTO_PAUSE_ALERTS = {DeadLetterFlood}` AND status=firing:
     also UPDATE `static_context.system.state` to `paused` with
     `paused_reason = 'auto_pause:DeadLetterFlood'`.

Master Router's Kill Switch Check polls `system.state` every 30s and
short-circuits when paused, so no events are claimed.

Resume is **explicitly manual** via the `/resume-all` slash command which
INSPECTS the paused_reason and prompts for human confirmation before flipping
state back to running.

## Consequences

**Positive:**
- Single sink for all Prometheus alerts → easy to extend (Telegram, email
  routing happens later in alert-sink, not at multiple sources).
- system_alerts table gives the dashboard a queryable alert history independent
  of Alertmanager retention.
- Auto-pause tested via synthetic alert payload; proven end-to-end.

**Negative:**
- Sole gating signal is `dead_letter_count` growth. Other catastrophic
  states (e.g. RLS leak, signing key mismatch) won't trigger auto-pause
  yet. Future alerts can be added to `AUTO_PAUSE_ALERTS` set in
  alert-sink-v1's Flatten node.
- Watchdog-n8n-errors and alert-sink overlap in spirit but not signal:
  watchdog watches n8n execution_entity errors, alert-sink watches Prometheus.
  Both write to system_alerts so the dashboard surfaces both.

## References

- SPEC §4.6 Failure Philosophy
- Alertmanager config: `/home_ai/monitoring/alertmanager.yml`
- Alert rules: `/home_ai/monitoring/prometheus-rules/home-ai-alerts.yml`
- Sink workflow: `/home_ai/.claude/n8n-exports/alert-sink.json`
- Resume command: `.claude/commands/resume-all.md`
