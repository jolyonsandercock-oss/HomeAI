# U155 — Cost + cache audit (30-day window, 2026-05-21)

## Scale

Total 30-day AI spend: **£0.69** across 255 calls. Sub-£1 per month at current operational volume. Well under any tier ceiling.

## Per-capability breakdown

| capability_tag | calls | prompt tokens | cache hit % | cost £ | priority for optimization |
|---|---:|---:|---:|---:|---|
| `CAP_EMAIL_CLASSIFY` | 212 | 203,598 | **0%** | 0.18 | medium — high volume but prompts ~960 tokens each, below Haiku's 5000-token cache threshold |
| `CAP_BOT_RESPONDER` | 18 | 59,042 (+102k cache read) | **63.3%** | 0.30 | low — already best-cached |
| `CAP_INVOICE_EXTRACT` | 2 | 85,924 | 0% | 0.08 | high — very large prompts (avg 43k tokens), well above Haiku's threshold |
| `CAP_DREAMING` | 7 | 10,304 | 0% | 0.10 | low — small calls, low volume |
| `CAP_GUEST_CONTACT` | 10 | 9,506 | 0% | 0.01 | low — short prompts (~950 tokens) |
| `CAP_REVIEW_DRAFT` | 2 | 2,410 | 0% | 0.01 | low — tiny volume |
| `CAP_COMPLIANCE` | 4 | 164 | 0% | 0.004 | none — prompts too short to matter |

## Findings

1. **Bot responder is well-cached (63.3%)** — Sonnet over the slug toolset benefits from the prompt cache; the long tool list is stable across calls. Already at the proven `feedback_prompt_cache_thresholds` pattern.

2. **Invoice extract has 0% cache despite 43k-token prompts** — huge opportunity. Each call reads a different PDF's extracted text, but the *prompt scaffolding* (extraction schema, examples) is shared. Moving the stable scaffold to a cacheable prefix would slash cost per invoice from ~£0.04 to ~£0.005.

3. **Email classify is below the cache threshold** — Haiku needs 5000+ tokens cacheable; current prompt is ~960. Either (a) restructure to include the slug catalog / known-vendor list to push past 5000 tokens (would actually reduce cost despite "more tokens" because cache reads are ~10x cheaper than prompt reads), or (b) accept it — at £0.18/month it's noise.

4. **Volume is too low to optimize hard** — at sub-£1/month total spend, the absolute savings from a 50% reduction is ~£0.30/month. Not worth a multi-day optimization sprint until volume grows.

## Recommendations

### Action item 1 — Invoice extract cache prefix (medium priority)

When invoice volume grows post-staff-rollout (currently ~0/day), refactor
`CAP_INVOICE_EXTRACT` prompts to put the extraction schema + few-shot
examples first (the cacheable scaffold), then the variable PDF text.

Expected reduction: 80-90% on per-invoice cost once volume is steady-state.

### Action item 2 — Email classifier (low priority)

Defer until classification volume exceeds 500/day. At current ~7/day rate,
optimization effort doesn't pay back.

### Action item 3 — Tier ceiling tune (defer until 90d of real data)

Current ceilings (P0=£0.90/day, P1=£1.05, P2=£0.63, P3=£0.42) are 5-10×
above actual peak usage. No tuning needed. Re-audit in Q3.

### Action item 4 — Phase 6 close — declare done

Optimization on a system burning sub-£1/month is premature. **Phase 6's
operational close-the-loop goals are met. Recommend declaring Phase 6
complete and moving to Phase 7 once staff rollout stabilises.**

## Phase 7 candidates (proposed)

1. **Revenue-side close-the-loop** — invoice → matched → recognised → reported. Currently we cover the cost side; revenue is unsurfaced. Highest £ value.
2. **Personal realm catch-up** — postponed family/property/mortgage surfaces from 2026-05-21 conversation.
3. **Multi-property scaling** — pattern for adding a second hospitality venue.
4. **Customer-facing** — booking widget, guest portal, breakfast pre-order.

## Status

- ✅ Cache hit-rate audit complete
- ✅ Cost spread quantified
- ✅ Phase 6 recommendation: ready to declare done after U151 sign-offs + U154 dress rehearsal
- ⏸ Prompt cache refactors (action items 1+2) deferred until volume justifies
