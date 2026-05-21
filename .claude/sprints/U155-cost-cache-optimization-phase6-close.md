# U155 — Cost/cache optimization + Phase 6 close

**Prereqs**: U151-U154 shipped. Staff in production.

**Realm**: `work`.

**Remote vs in-person**: 100% remote.

**Why this sprint exists**: Phase 6 close. The system is live to staff; cost data has 30+ days of real load to optimize against. Steady-state lets us actually measure tradeoffs.

## Tracks

### T1 — Prompt cache hit-rate audit (~90 min)

**Realm**: `work`.

**Build**:
- Per `capability_tag`, compute `cache_read_tokens / (prompt_tokens + cache_read_tokens)` ratio over last 30 days.
- Sort by lowest hit rate × highest call volume = highest-value-to-fix.
- For the top 5 misses: inspect the prompt; identify whether a stable prefix could be cacheable (per `feedback_prompt_cache_thresholds`).
- Refactor prompts to put stable content first (1024+ tokens for Sonnet, 5000+ for Haiku).

**Acceptance**: top-5 cacheable prompts refactored; weighted average cache hit-rate up by >20pp.

### T2 — Model routing review (~60 min)

**Build**:
- Per `capability_tag`, look at `model_used` distribution + success rate (where success ≈ `escalated=false`).
- Identify: (a) Sonnet calls where Haiku would have worked (downgrade), (b) Haiku calls escalating frequently (upgrade).
- Update llm-router routing table; refresh.

**Acceptance**: routing changes documented; 30-day cost projection shows ≥15% reduction without success rate drop.

### T3 — Tier ceiling auto-tune (~45 min)

**Build**: based on 30d trailing P99 spend per tier, propose new ceilings via `V181__u155_quota_ceiling_v2.sql`. Don't apply automatically — present as recommendation in `audits/u155-quota-tune.md`.

**Acceptance**: doc written with old vs proposed ceilings + rationale.

### T4 — Sonnet 4.6 → 4.7 upgrade check (~30 min)

**Build**:
- Run model-evaluator on top capability_tags against Sonnet 4.7.
- If 4.7 wins on quality OR cost at parity, propose upgrade.

**Acceptance**: recommendation written; if positive, apply.

### T5 — Phase 6 retrospective (~60 min)

**Build**: write `2026-MM-DD-phase-6-close.md` ADR summarising:
- What U138-U155 delivered.
- Phase 6's gating criteria (operational close-the-loop, staff-ready) — were they met?
- What Phase 7 should be anchored around. Candidate themes:
  - Cost recovery (revenue-side: invoice → matched → recognised)
  - Personal realm features (the items postponed in 2026-05-21 conversation)
  - Multi-property scaling
  - Customer-facing surfaces (booking widget, guest portal)

**Acceptance**: ADR committed + linked from MEMORY.md.

## Done criteria

- Cache hit-rate up >20pp on top capability_tags.
- Routing changes shaved ≥15% off 30-day cost projection.
- Tier ceiling tune proposed (apply requires sign-off).
- Phase 6 retrospective committed.

## Risk

Low. Optimization on a stable system is mostly measurement → tweak → re-measure. No new architecture, no schema migrations apart from the optional V181.

## What's next after Phase 6

Phase 7 candidates (to be ADR'd in T5):
- **Revenue-side close-the-loop**: invoice → matched → recognised → reported. Currently Phase 6 covered the cost side; revenue is unsurfaced.
- **Personal realm catch-up**: the in-person scans, family / property surfaces that were postponed.
- **Multi-property scaling**: pattern for adding a second hospitality venue.
- **Customer-facing**: booking widget, guest portal, breakfast pre-order.
