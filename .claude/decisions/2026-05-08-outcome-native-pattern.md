# ADR — Outcome-Native pipeline pattern

**Date:** 2026-05-08
**Status:** Accepted (SPEC v5.3 §6.2 mandate; live in gmail-ingest-v1, P8, P9, P2)
**Supersedes:** earlier confidence-only escalation in gmail-ingest

## Context

Anthropic's May 2026 release introduced Outcomes — typed, validated returns
from agents that include status, confidence, reasoning, and the structured
data extracted. SPEC v5.3 lifts this as a pattern Home AI should implement
locally (not adopt as a managed-cloud feature).

Before the pattern, our AI worker Code nodes returned ad-hoc shapes
(`ai_category`, `ai_confidence`, `needs_escalation` flag). Each pipeline's
escalation logic was hand-rolled — one used Anthropic Haiku, one threshold
checked confidence directly, one didn't escalate at all. `audit_log.ai_parsed`
held inconsistent shapes that couldn't be queried uniformly.

## Decision

Every AI worker Code node returns this exact shape:

```js
{
  status:         'success' | 'escalate' | 'fail',
  confidence:     <0.0..1.0>,
  reasoning:      string,
  data:           { ... worker-specific extracted fields },
  requires_human: boolean,
  worker:         string,    // e.g. 'email_classifier'
  tier_used:      'hot' | 'medium' | 'haiku' | 'sonnet' | ...
}
```

Status derivation rule, applied uniformly across all pipelines:

- `confidence ≥ threshold`               → `success`
- `threshold × 0.85 ≤ confidence < threshold` → `escalate` (retry on next tier)
- `confidence < threshold × 0.85`        → `fail` (set requires_human=true)

`audit_log.ai_parsed` stores the OutcomeObject as JSONB. `result` column
mirrors `outcome.status` for fast filtering. Dashboard outcome registry +
Dreaming workflow both consume `ai_parsed` directly.

## Consequences

**Positive:**
- Uniform queryability — `SELECT pipeline, ai_parsed->>'status' FROM audit_log` works the same everywhere.
- Dashboard outcome registry shows confidence, reasoning, tier consistently.
- Drift alerting per pipeline is straightforward (count outcome.fail by worker).
- Dreaming workflow can summarise failure patterns by reading ai_parsed.

**Negative / known cost:**
- Every existing AI Code node had to be patched (4 nodes in gmail-ingest, 1 each in P8/P9/P2).
- New pipelines need to follow the convention or the dashboard misses them.
- Escalation tier lookup currently hardcodes 'haiku' — Phase 2 should pull
  from `static_context.model.tiers.medium` so the cold tier is configurable.

## References

- SPEC v5.3 §6.2 "Pipeline Construction Rules — Outcome-Native Pattern"
- HOME-AI-STRETCH-v2.0 §3.12 "Anthropic May 2026 Features — Local Implementations"
- Implementation: `gmail-ingest-v1` Parse Ollama/Haiku Response nodes,
  `nanny-v1` Build OutcomeObject, `report-ingestion-v1` Build OutcomeObject,
  `invoice-pipeline-v1` Build OutcomeObject + Idem Key.
