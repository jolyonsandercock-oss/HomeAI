# U150 — Invoice loop closure + Phase 6 kickoff

**Prereqs**: U128 (Xero ingest + Dext auto-forward), U68 (doc auto-classifier), U79 (mortgage statement coverage), U146 (pipeline stability).

**Realm**: `work` mostly, with `personal` for mortgage statements (per realm pivot).

**Remote vs in-person**: T1-T3 fully remote, T4 hybrid (some need Jo physically).

**Why this sprint exists**: Phase 5 hardening lands the AI guardrails. Phase 6 should deliver the *operational* close-the-loop value Jo's been building toward — every invoice categorised, every mortgage statement collected, every orphan reconciled. £-impact: correct VAT.

## Tracks

### T1 — Dext orphan backfill (~45 min)

**Realm**: `work`.

**Why**: U128 auto-forwards orphan-after-7-days invoices to `malthousepub@dext.cc`. ~63 were forwarded as smoke test 2026-05-17. Of those, some have come back via Xero (closing the loop); some haven't. Need to identify the still-orphans and decide: re-forward, give up, manually enter, or chase vendor.

**Build**:
- Query `xero_vs_email_orphans` slug with `--days 30 --detail`.
- For each orphan ≥21 days old: check Dext mailbox via Gmail API for matching `Re:` or processed-confirmation.
- Output `audits/u150-orphans-status.md` with: came-back / still-orphan / never-forwarded.
- For "never-forwarded" (auto-forward cron failed silently?): manually trigger forward.

**Acceptance**: every email-pipeline invoice >21 days old is either (a) matched to a Xero bill, or (b) on the orphans-list with a documented next-action.

### T2 — Surface /admin/documents/review (~30 min)

**Realm**: `work`.

**Why**: U68 doc auto-classifier identified unmatched documents. Review UI exists but is poorly linked from main nav.

**Build**:
- Add "Document Review" tile to /admin (count of pending review items, click → /admin/documents/review).
- Slug `documents_pending_review_count` (new).

**Acceptance**: tile shows live count; clicking lands on review queue.

### T3 — Mortgage statement coverage tile (~45 min)

**Realm**: `personal`.

**Why**: V79 created a `v_mortgage_statement_coverage` view. No frontend.

**Build**:
- New slug `mortgage_statement_gaps` — accounts × months missing a statement.
- Tile on /private/docs surfacing the count + most-recent-gap account.
- Click → /private/docs/mortgages page (existing) with the gap pre-filtered.

**Acceptance**: Castle Rd / Salutations / Olde Malthouse / Langholme statement gaps visible.

### T4 — In-person packet for next physical session (~60 min)

**Realm**: cross-cutting.

**Build**: consolidated checklist `audits/u150-in-person-packet-<date>.md` of items needing Jo's physical access:
- Bank card / statement scans not yet in Paperless.
- Property-related documents (Castle Rd inspection reports, Olde Malthouse fire-safety, etc.).
- Original receipts for VAT-flagged invoices >£100.
- Any pending Vault rotation tasks (per `vault rotation calendar`).

Modelled on U90's pattern but driven by current state, not historical.

**Acceptance**: checklist generated; Jo can work through it on next physical session.

### T5 — Phase 6 wraparound (~30 min)

**Build**:
- Update `STATUS.md` via `scripts/u89-regen-status.sh`.
- Write decision file `2026-MM-DD-phase-6-kickoff.md` summarising what shipped in Phase 5 and what Phase 6 is anchored around (operational close-the-loop).
- Memory update: project_homeai.md (phase += 1).

**Acceptance**: STATUS + decision committed.

## Done criteria

- Orphan invoice count <10 (down from ~63).
- /admin/documents/review tile live.
- /private/docs mortgage statement gap tile live.
- In-person packet checklist exists for next session.
- Phase 6 ADR committed.

## Risk

Low. Mostly read + surfacing + small backfills. No schema changes; no live behaviour changes.
