# DECISION: keep the n8n + cron hybrid (posture A) — 2026-06-20

**Status: DECIDED.** The n8n retirement migration is **formally cancelled.**

## Decision
Keep **n8n** as a bounded **webhook + event-dispatch layer** (Gmail ingest, event routing via
Master Router, alerting sink, the P2/P5/P6/P9 pipelines). Keep **cron sweeps** for scheduled
pulls (EPoS, accommodation, bank, labour, invoice PDF extraction, Metis, etc.). **Do not**
migrate alerting off n8n, rebuild the email ingestion path, or build custom webhook
micro-services. Invest in **observability** instead. **Reassess in ~6 months** (target 2026-12).

## Why (evidence, measured 2026-06-20)
- n8n is the live core, not vestigial: **Master Router 2,880 runs/24h (≈every 30s, 98.3% success)**,
  Gmail Ingest 323, Invoice P2 active, all Prometheus alerting routed through the n8n sink.
- A permanent *two-engine* hybrid was the only thing to avoid; a *bounded* hybrid with clean,
  non-overlapping responsibilities is a perfectly good end state for a solo-operated system.
- External review (GPT-5.5, 2026-06-20) and the in-house Hermes review both independently reached
  posture A + "fix observability first."

## What the decision rests on
The real problem was never the architecture — it was that **we couldn't see it working or
failing**. Correcting that is the whole job:
1. **Heartbeat observability** (`ops.pipeline_runs`) — every pipeline records run/status/duration on
   top of the existing data-freshness watchdogs. (Mechanism shipped 2026-06-20: `ops.record_pipeline_run()`
   + `scripts/ops-run.sh`; rollout incremental.)
2. Triage real failures (done 2026-06-20: overnight email outage replayed; ~24 supplier invoices
   recovered) and keep them visible.

## Supersedes
- The "n8n is largely DEAD / retire it" framing in earlier docs — **factually wrong**, corrected in
  `SYSTEM_ARCHITECTURE.md` §0 and the auto-memory on 2026-06-20.
- The retirement-readiness draft (`n8n-retirement-readiness-2026-06-20.md`) — kept only as an
  artifact; its conclusion is overridden by this decision.

Full analysis + the 6 review questions: `n8n-decision-for-gpt55-review.md`.
