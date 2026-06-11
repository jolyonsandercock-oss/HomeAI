# Design for review — Anchor-First Resolver + Abstention Gate

> A concrete application of Sibyl Memory's "exact-entity recall + principled refusal" thesis to a real financial entity-resolution problem, plus the agent-memory layer. Written for an external reviewer with no prior context.

---

## 0. Reviewer role
You are a skeptical staff engineer with an information-retrieval background. Your job is to find where this design is **wrong, oversold, or fragile** — not to praise it. Pay special attention to (a) the abstention thresholds, (b) the cases where exact/lexical anchoring silently fails, and (c) whether the claimed benefits actually need this architecture vs. a tuned hybrid retriever. Read-only critique.

---

## 1. Background (you have none of this — read it)

**The system.** A local-first, event-driven data platform for a small group of businesses: a pub/inn Ltd (entity 1), a property-holding Ltd (entity 2), personal/family (entity 3). It ingests **bank transactions, supplier invoices, EPoS/till reports, and emails** and attributes each record to the correct business entity, property, and expense category. Source-of-truth systems (accounting, bank, EPoS) are never overridden.

**Memory layer (separate concern, addressed in §6).** Agent memory is **file-based, no vectors**: markdown "fact" files with frontmatter, plus a flat index loaded into context each session. ~50 facts today.

**The thesis we're applying (Sibyl Memory).** For long-horizon memory over many near-duplicate entities, *retrieval precision under near-duplicate pressure* matters more than context volume. Similarity/vector search returns a **nearest neighbor**, so (i) it confuses entity 001 with entity 153 when the discriminating signal is a single token, and (ii) for an entity that doesn't exist it confidently returns a real neighbor instead of refusing. The proposed fix is exact-entity (lexical) anchoring + abstention, for near-zero tokens and cost. We accept the narrow form of this claim and want to apply it where it's strongest.

**The concrete problem.** Every incoming financial record carries a **free-text counterparty string** — e.g. a bank narrative `"ATLANTIC CONSTRUCT LTD BACS"`, an invoice supplier `"J&R Foodservice"`, a DD reference `"PRINCIPALITY BS 295905-02"`. The system must resolve each to a **canonical counterparty entity**, which in turn fixes the business entity / property / category. Two properties make this exactly the near-duplicate case:
- Names overlap heavily (multiple "Atlantic*" entities; the same vendor billed to two different accounts — `J&R` on the cafe account `MAL125` vs. the pub-kitchen account `TOM106`).
- **Mis-attribution is a financial error, not a bad search result.** Assigning a payment to the wrong entity corrupts the books. (This system has already had one reconciliation error from exactly this class.) So "confidently return the nearest neighbor" is the worst possible behavior.

Current resolution is rule/lexical (alias tables, domain patterns, account→entity maps) — i.e. the system already avoids vectors here. This design formalizes and hardens that into an explicit resolver + abstention gate.

---

## 2. Data model — tiered by volatility (per Sibyl)

- **Durable entity graph** — `counterparty_registry`: canonical name, type, owning entity/realm; plus edges: `aliases[]`, `account_numbers[]`, `email_domains[]`, and relationships (`bills_to_account`, `cross_collateralised_with`, `subsidiary_of`). Account numbers and domains are near-unique → strongest anchors.
- **Event log (append-only)** — `resolution_log`: every confirmed `(raw_string → counterparty_id, anchor_tokens, confidence, who_confirmed)`. A human-confirmed mapping becomes a learned alias, so the *second* time a narrative appears it's a deterministic exact hit. This is the "memory" that compounds.
- **Live** — the current ingest batch's working set.

---

## 3. Anchor-first resolver (the algorithm)

```
resolve(raw_string) -> Resolution | Abstain

1. normalize: uppercase, strip legal suffixes (LTD/LIMITED/PLC/&CO),
   strip bank cruft (BACS/DD/FPS/REF/dates), collapse whitespace.
2. tokenize -> tokens; also extract STRONG anchors: account numbers (\d{6,}),
   sort-codes, email domains, postcodes.
3. STRONG-anchor pass: if a strong anchor (account no. / domain) exactly
   matches exactly one registry edge -> return that entity, confidence=HIGH.
   (This is how "PRINCIPALITY ... 295905" resolves deterministically even
   though "Principality" alone is ambiguous across cross-collateralised loans.)
4. else LEXICAL pass over a SQLite FTS index of {canonical, aliases}:
   - rank candidate tokens by ascending document-frequency (rarest first;
     DF precomputed across the registry). Rarest token = most discriminating.
   - query FTS for the rarest token. If it hits exactly one entity -> candidate.
     If >1, AND with the next-rarest token; repeat until a single entity remains
     or tokens are exhausted.
   - score = f(coverage of raw_string by matched tokens, rarity of the
     discriminating token, margin between top-1 and top-2).
5. consult resolution_log first for an exact prior mapping (learned alias) ->
   instant HIGH-confidence hit, no FTS needed.
6. hand the scored top candidate(s) to the abstention gate (§4).
```

No embeddings, no model call, deterministic. Cost ≈ a couple of indexed SQLite lookups.

---

## 4. Abstention gate (the part that matters most)

```
gate(candidates) ->
  HIGH   : strong-anchor unique match, OR a discriminating token (DF<=k)
           uniquely identifies one entity AND margin(top1,top2) >= M
           -> auto-resolve, write resolution_log
  LOW    : a candidate exists but no token is discriminating enough, OR
           top1/top2 margin < M, OR coverage < C
           -> ABSTAIN: emit `unresolved(raw_string, top_candidates[])` to a
              human-review queue. NEVER auto-assign.
  NONE   : no token clears the DF/coverage floor at all (e.g. every token is
           a common word like ATLANTIC / SERVICES / CONSTRUCTION)
           -> ABSTAIN: `unresolved(reason=no_anchor)`, offer "create new
              counterparty?"  NEVER map to a near-name.
```

The contract: **the resolver returns the *right two rows or nothing*.** It is never allowed to attribute money to a "closest" entity. This is the §1 "fake company → refuse" behavior, but the stakes are a corrupted ledger rather than a wrong chat answer.

---

## 5. Worked examples

| Incoming string | Anchor used | Result |
|---|---|---|
| `J&R FOODSERVICE INV 567446 ... TOM106` | account `TOM106` (strong) | HIGH → J&R, pub-kitchen account (not cafe `MAL125`) |
| `PRINCIPALITY BS 295905-02 DD` | account `295905-02` (strong) | HIGH → the specific cross-collateralised loan (disambiguates "Principality" across several) |
| `ATLANTIC ROAD TRADING LTD` | token `TRADING` (rare) + `ROAD` | HIGH → entity 1 |
| `ATLANTIC CONSTRUCT LTD BACS` | tokens all common-ish; no registry edge for `CONSTRUCT`; "Atlantic*" matches 3 entities, margin too low | **ABSTAIN** → human review. (A similarity system maps this to "Atlantic Road Trading" and silently mis-posts a payment — the exact failure to prevent.) |
| `J&R FOODSVC` (typo/abbrev, no account) | `J&R` ambiguous, `FOODSVC` not in index | LOW → ABSTAIN with J&R candidates surfaced; once a human confirms, `resolution_log` makes it a permanent exact hit |

---

## 6. Same pattern, applied to the agent memory layer

The file-based memory currently loads the whole index into context and lets the model pick. Anchor-first version: on a recall query, take the rarest discriminating keyword, return **the one or two matching fact files** (not all 50), and **abstain** ("no memory on this") when nothing matches the keyword set — instead of surfacing a loosely-related fact the model then over-trusts. Honest caveat: at ~50 facts this is premature optimization; it earns its keep at hundreds/thousands.

---

## 7. Where this is NOT the right tool (stated up front so you can attack it)

- Queries that **don't contain the discriminating token** — paraphrase, vocabulary mismatch, "the supplier we had the delivery dispute with." Anchoring has nothing to grip; you need semantic recall there. We claim those are rare in *financial attribution* (records carry names/IDs, not prose) but common in *conversational* memory.
- **Garbled/OCR'd or phonetic name variants** of short entity names. The right fuzzy fallback here is edit-distance / trigram / phonetic (e.g. `pg_trgm`, Soundex) — **not** dense vectors, which are weak on short proper nouns. The design treats the fuzzy tier as trigram/phonetic, gated by the same abstention logic.

---

## 8. Review questions — red-team these

1. **Abstention calibration.** The whole value rests on the HIGH/LOW/NONE thresholds (DF cutoff `k`, margin `M`, coverage `C`). How would you set and validate them without overfitting? What's the failure mode if `M` is too low (false auto-resolve) vs. too high (everything abstains → human-review queue floods and gets rubber-stamped)?
2. **Silent lexical failure.** Where does rarest-token anchoring *confidently return the wrong entity* (not abstain)? e.g. a rare token that's a typo of a different entity's rare token; an alias collision. Is the margin check enough?
3. **DF maintenance.** Document-frequency drifts as the registry grows and as `resolution_log` adds aliases. Does "rarest token" stay stable, or does anchoring degrade over time? How would you keep it honest?
4. **Is the architecture necessary?** Could a tuned **hybrid retriever (BM25 + reranker) with an exact-match/abstention gate bolted on** get the same financial-attribution accuracy? If yes, the novel contribution is the *abstention gate + tiered learned-alias log*, not "no vectors." Argue it either way.
5. **Abstention as a metric.** We propose grading the resolver on three axes: correct-resolve, **correct-abstain** (refused when it should), and the two error types (wrong-resolve, wrong-abstain). Is that the right scorecard? What's missing — e.g. cost of a human-review item, time-to-learned-alias?
6. **Strong-anchor trust.** Account numbers/domains are treated as near-unique HIGH anchors. Where does that break (shared DD references, recycled account numbers, a domain used by two entities)?
7. **Generalization claim.** §6 asserts the same machinery serves agent memory. Does the financial-attribution shape (records carry IDs) actually transfer to conversational memory (queries are prose)? Or is that an overreach?

---

## 9. Output format requested
Verdict (**sound / sound-with-changes / flawed**), then a numbered list of the strongest objections with concrete failure cases, then the single change that would most improve it. Prioritise §8.2 (silent wrong-resolve) and §8.4 (is the architecture necessary) — those are where we're least sure.
