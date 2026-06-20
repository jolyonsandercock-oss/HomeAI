# Metis — Task Self-Improvement Loop (design)

**Date:** 2026-06-20
**Status:** approved design → ready for implementation plan
**Pilot:** invoice categorisation · **Task #2 (baked in):** the "is-invoice" filter

> *Metis* (Greek: practical wisdom / wise counsel). The loop **advises** — it proposes,
> it never decides. Apply is always human-gated. The name encodes the guarantee.

---

## 1. Problem & goals

We want every processing task to improve continuously — refine its rules, learn from
mistakes, optimise over time — **without** (a) slowing the live hot path, (b) becoming a
review bottleneck, or (c) introducing LLM hallucination drift into financial data.

Today the building blocks exist but are fragmented and mostly single-task:
- **Capture:** `invoice_feedback` (lifecycle: `ai_proposal → applied_at/applied_rules → rejected_at`), `line_category_feedback`, `bot_feedback` — but `invoice_feedback` has 0 rows (built, unfed).
- **A proto-loop:** `u44-feedback-applier.sh` turns Jo's plain-text feedback into one of 5 structured actions via Sonnet, **never auto-applies**, routes to the **`v_action_queue`** for approval.
- **Benchmark/eval:** `cognition.benchmark` + `homeai-model-evaluator`.
- **Gate:** `audit-invariants.py` (pre-push).

**Metis generalises this into one reusable, task-agnostic, recursive envelope**, proven on
categorisation, with the is-invoice filter as the second adopter. It does **not** replace
the live tasks and it **subsumes** (does not duplicate) the existing invoice-feedback loop.

### Non-negotiable principles
1. **Deterministic detection.** A "mistake" is only ever asserted by a ground-truth signal
   (a gap, a contradiction, a human correction, a gate failure) — never "an LLM thinks this
   is wrong." LLMs may *draft a proposal*, always labelled `llm_suggested`, always gated.
2. **Human-gated apply.** Nothing touches live config/data automatically. Status flows
   `pending → approved|rejected → applied → measured → (maybe) reverted`.
3. **Frozen-benchmark recursion.** Improvements are measured against a fixed, human-owned
   label set — never the loop's own evolving judgment. This is what keeps a self-improving
   loop anchored to reality.
4. **Off the hot path.** The whole loop is async/nightly. The live task never waits on it.
5. **Reversible.** Every applied change records its inverse so MEASURE can auto-revert.

---

## 2. The envelope — five stages beside (never inside) the task

```
   live hot path (unchanged, fast)
   invoice → categorise-sweep (deterministic rule match, ~4s, no LLM) → categorised / NULL
                          │ emits cheap append-only outcome rows
                          ▼
   ┌──── Metis loop (nightly, async, no bottleneck) ─────────────────────────────┐
   │ 1 OBSERVE  one cognition.task_runs row per task run (coverage%, counts, …)   │
   │ 2 DETECT   deterministic detectors → candidate mistakes/gaps                 │
   │ 3 PROPOSE  concrete REVERSIBLE action + evidence + £impact + predicted_effect│
   │ 4 REVIEW   Hermes auto-approves provably-safe subset; rest → digest + queue; │
   │            reject is remembered (cognition.proposal_rejections)              │
   │ 5 MEASURE  actual effect vs predicted vs FROZEN benchmark; regression →      │
   │            auto-raise corrective proposal   ◄── recursive close              │
   └─────────────────────────────────────────────────────────────────────────────┘
```

**Recursive close:** stage 5 feeds stage 1. Applying a learned rule produces new
observations; if the rule was too broad (e.g. catches a >£1k mismatch) or dropped coverage
on a previously-good vendor, Metis *notices its own mistake* and raises a corrective
proposal (`reverts_proposal_id`). Rejected proposals become negative examples so the
proposer stops re-suggesting them. The loop learns what to propose **and** what not to.

**No-bottleneck answers to the three constraints:**
- *Compute:* loop is nightly/async; hot path never blocks on it; OBSERVE is append-only.
- *Review:* Hermes pre-triages and auto-approves the provably-safe class; digest is top-N by
  £; rejects are remembered so the queue never repeats itself.
- *Hallucination:* detection is always deterministic; LLM output is advisory + labelled +
  gated + benchmark-checked.

---

## 3. The reusable contract (how any task joins)

The generic machinery — `proposals` queue, rejection memory, digest, dashboard widget,
benchmark gate, MEASURE step — is written **once**. A task joins by implementing three hooks:

| Hook | Returns | Categorisation impl | Is-invoice impl |
|---|---|---|---|
| `observe(run)` | a `cognition.task_runs` row | coverage%, counts, mismatches | precision/recall proxy, escalation rate, classifier disagreements |
| `detect()` | `cognition.proposals` rows | 4 detectors (§4) | 3 detectors (§5) |
| `apply(p)` / `revert(p)` | enact / undo | insert/narrow/retire `vendor_category_rules` | upsert/retire `invoice_noise_senders|subjects`; propose threshold change |

Each hook is a small task-specific script; everything else is shared. Counterparty
resolution and line extraction later adopt by writing only their `detect`/`apply`.

---

## 4. Pilot task #1 — invoice categorisation

**Hot path unchanged:** `u-invoice-categorise-sweep` stays a ~4s deterministic UPDATE.

**Detectors (all deterministic):**

| Detector | Ground-truth signal | Apply action |
|---|---|---|
| **GAP** | uncategorised invoices grouped by vendor, ranked Σnet | `rule_insert` (category = majority of that vendor's already-categorised siblings; else `llm_suggested`) |
| **CONTRADICTION** | one `vendor_domain` resolves to ≥2 categories | `rule_insert`/`rule_narrow` (often a site split, e.g. J&R cafe vs kitchen) |
| **CORRECTION** | Jo re-categorised (`invoice_feedback` / `line_category_feedback`) | the rule that produced the old value → `rule_narrow`/`rule_retire` + new `rule_insert` |
| **OVER-BROAD / DEAD** | rule fired on a >£1k mismatch, or hasn't matched in N days | `rule_narrow` / `rule_retire` (the intuit/xero/sage platform-forwarding case lives here) |

**Apply target:** `vendor_category_rules` (`domain_pattern, category, site, priority, realm`).
Reversible: an insert's inverse is a delete-by-id; a narrow/retire snapshots the prior row.

**Correction capture:** the dashboard "re-categorise" control writes `invoice_feedback`
(reusing its `ai_proposal` lifecycle) — this *also* feeds `u44-feedback-applier`, which Metis
absorbs as the CORRECTION detector's proposal-drafting step rather than a parallel system.

---

## 5. Task #2 (baked in) — the "is-invoice" filter

The is-invoice decision is the email/document classifier (`gmail-ingest`: qwen2.5:7b →
Haiku escalation, confidence-gated into `invoice | … | junk`; `report-ingestion`:
`supplier_invoice | …`). It runs **concurrently** and is partly being worked on elsewhere —
Metis **observes and proposes refinements to it; it does not fight or gate it.**

**Detectors (deterministic):**

| Detector | Ground-truth signal | Apply action |
|---|---|---|
| **FALSE-POSITIVE** | classified `invoice` but Jo flagged `flag_as_statement` / `flag_as_ignored` (via `invoice_feedback`), or it's a refund/notification | upsert `invoice_noise_senders` / `invoice_noise_subjects` (deterministic suppression) |
| **FALSE-NEGATIVE** | a real invoice landed in `fyi`/`junk` (later corrected, or matched a known vendor_domain that normally invoices) | propose sender/subject allow-hint + flag for threshold review |
| **LOW-CONFIDENCE / DISAGREEMENT** | sustained escalation rate, or qwen↔Haiku disagree on a sender repeatedly | propose a classifier `min_confidence` threshold change (to `ai.thresholds`) **as a gated proposal**, never an auto-edit |

**Apply targets:** `invoice_noise_senders`, `invoice_noise_subjects` (reversible via
`active=false`), and threshold proposals against `static_context['ai.thresholds']`.
**Coordination:** Metis treats the live classifier as read-only; all its outputs are
proposals in the same queue, so the concurrent build and Metis cannot collide.

---

## 6. Data model

**New — `cognition` schema, all task-agnostic:**

```sql
-- OBSERVE: one row per task run, any task
cognition.task_runs(
  id bigserial pk, task_id text, run_at timestamptz default now(),
  metrics jsonb,            -- {coverage_pct, population, categorised, mismatch_over_1k, ...}
  duration_ms int);

-- PROPOSE + REVIEW: the shared queue
cognition.proposals(
  id bigserial pk, task_id text, detector text,        -- gap|contradiction|correction|overbroad|dead|false_pos|false_neg|low_conf
  entity_ref text,                                      -- vendor_domain / sender / inbox id
  action_kind text,                                     -- rule_insert|rule_narrow|rule_retire|noise_add|threshold_change
  action_payload jsonb,                                 -- exact reversible change
  revert_payload jsonb,                                 -- precomputed inverse
  evidence jsonb,                                       -- sample invoice ids, counts
  impact_gbp numeric, confidence numeric,
  category_source text,                                 -- deterministic|llm_suggested
  predicted_effect jsonb, measured_effect jsonb,
  status text default 'pending',                        -- pending|approved|rejected|applied|reverted|auto_approved
  created_at timestamptz default now(),
  decided_by text, decided_at timestamptz, applied_at timestamptz,
  reverts_proposal_id bigint references cognition.proposals(id),
  realm text,
  unique(task_id, detector, entity_ref, action_kind)); -- dedupe re-proposals

-- negative memory: signatures the proposer must suppress
cognition.proposal_rejections(
  id bigserial pk, task_id text, signature text,        -- hash(detector, entity_ref, action_kind)
  reason text, rejected_by text, rejected_at timestamptz default now(),
  unique(task_id, signature));

-- FROZEN ground-truth labels (separate from the model-eval `cognition.benchmark`)
cognition.benchmark_labels(
  task_id text, key text, expected text,                -- ('invoice.categorise','flogas.co.uk','gas')
  added_by text, added_at timestamptz default now(),
  primary key(task_id, key));
```

**Reused as-is (audit-consumers-before-replacing — these stay, Metis wraps them):**
- `vendor_category_rules` — categorisation apply target.
- `invoice_noise_senders` / `invoice_noise_subjects` — is-invoice apply target.
- `invoice_feedback` (`ai_proposal`/`applied_*`/`rejected_*` lifecycle) + `line_category_feedback` — CORRECTION signal; `u44-feedback-applier` becomes Metis's proposal-drafting step for the correction detector.
- `v_action_queue` / `v_action_queue_stratified` — the review surface; the dashboard widget reads a `cognition.proposals`-backed extension of it.
- `static_context['ai.thresholds']` — threshold-change proposals target this (gated).
- `cognition.benchmark` / `homeai-model-evaluator` — MEASURE may reuse for model-tier tasks.

RLS: new tables carry `realm` and the standard `entity_isolation`/`realm_isolation`
policies + GUCs, per the realm-in-every-table rule.

---

## 6a. Concurrent work & HARD file boundaries (read before implementing)

A parallel session (2026-06-20, `session_013Riqf…`) is **actively building the invoice
pipeline**. Metis **observes these as read-only producers and MUST NOT modify them**:

| Asset (owned by the other work) | What it is | Metis's relationship |
|---|---|---|
| `scripts/invoice-line-extract.py` → **`classify_doc()`** | the **is-invoice gate** — deterministic *text-only, no-model* triage that gates out statements/remittances/chasers (commit `0a698c3`) | Metis Task #2 **observes** its statement/invoice verdicts and proposes *additions to its patterns / `invoice_noise_*`*; it does **not** reimplement or edit `classify_doc()` |
| `scripts/invoice-line-extract.py` → **`learned_example()`** | the **layout-learning loop** — high-conf (cross-foot ≥0.92) extractions auto-prime the same supplier's prompt (commit `38fec2b`); a *closed, safe, auto* loop (no rules written, no human gate needed) | Metis **complements, never replaces** it: the line-extraction adopter (P5) only adds OBSERVE/MEASURE telemetry around it (does learned-priming actually lift accuracy?), and **does not touch the file** |
| `scripts/u-invoice-line-sweep.sh`, `scripts/wire-invoice-pipeline-vision-gemma4.py`, `scripts/u-invoice-categorise-sweep.sh`, `scripts/invoice-pdf-date-extract.py` | live extraction / categorisation hot paths (recently or in-flight modified) | **read-only**; Metis adds a *separate* `improve-*.sh` companion, never edits these |

**Rule of engagement:** Metis only ever (a) reads these producers' outputs from the DB, and
(b) writes to its **own** `cognition.*` tables + the gated apply-targets
(`vendor_category_rules`, `invoice_noise_*`, `ai.thresholds`). New Metis code lives in
**new files** (`scripts/metis-*.sh`, `scripts/metis/`), never inside the invoice-pipeline
files above. This keeps the two streams merge-clean.

**Note on extraction model:** the pipeline is on **gemma4-doc** (`think:false`), reverted
from qwen2.5:72b (commit `0a698c3`). Any Metis text referencing the extractor must say
gemma4, not qwen — and Metis does not change model choice.

---

## 7. Review surfaces (no review bottleneck)

- **Telegram digest** (act): nightly, top-N pending proposals ranked by `impact_gbp`,
  one-tap approve/reject via the existing critical-listener/bot path. Hermes pre-triages and
  **auto-approves only the provably-safe class**: `category_source='deterministic'` + vendor
  already consistently categorised elsewhere + change only fills NULLs + `impact_gbp ≤` the
  configured threshold (starts conservative, e.g. £250) + passes the benchmark dry-run.
- **Dashboard "Proposals" widget** (backlog): full queue browser with evidence, sample
  invoices, £impact, predicted effect; batch approve/reject. Built on `cognition.proposals`,
  surfaced alongside the existing `v_action_queue`.
- **Reject is learning:** writes `cognition.proposal_rejections`; the proposer left-joins it
  so the same proposal never re-surfaces.

---

## 8. MEASURE — the recursive close, concretely

On `apply`: snapshot a baseline + store `revert_payload`. The next nightly OBSERVE row gives
the actual delta; Metis writes `measured_effect` and compares to `predicted_effect`.
A change is flagged **regressive** if it: introduced a new >£1k mismatch, dropped coverage on
a previously-good vendor, or would mislabel any `cognition.benchmark_labels` row. A regressive
applied change auto-raises a corrective proposal (`action_kind=rule_narrow|rule_retire`,
`reverts_proposal_id` set). The **frozen benchmark gate** also runs at PROPOSE time: any
proposal that would mislabel a benchmark vendor is auto-rejected before it ever reaches you.

**North-star metrics** (tracked in `task_runs`, charted on the dashboard):
categorisation **coverage %** ↑ and **>£1k mismatch rate** ↓; is-invoice **false-pos/neg
rate** ↓ and **escalation rate** ↓.

---

## 9. Rollout

1. **P1 — generic spine:** create `cognition.task_runs|proposals|proposal_rejections|benchmark_labels`; the shared digest + dashboard widget + benchmark gate + MEASURE step.
2. **P2 — categorisation adopter:** `observe/detect/apply/revert` for categorisation; seed `benchmark_labels` from the current top categorised vendors; run shadow (propose-only, no auto-approve) for ~1 week.
3. **P3 — enable auto-approve** for the provably-safe class once the benchmark + shadow week show zero bad applies.
4. **P4 — is-invoice adopter:** observe **`classify_doc()`** verdicts read-only (§6a); `detect/apply` proposes `invoice_noise_*` / threshold refinements only. **Gated on the parallel invoice-filter session settling** — do not start P4 while `invoice-line-extract.py` is in active flux.
5. **P5 — line-extraction adopter (telemetry only):** wrap the existing **`learned_example()`** layout-learning loop with OBSERVE/MEASURE (does priming lift cross-foot pass-rate?). **Add no logic to `invoice-line-extract.py`**; read its outputs, write `cognition.task_runs`. Then document the 3-hook contract; counterparty resolution adopts.

---

## 10. Out of scope (YAGNI)
- No auto-apply beyond the narrowly-defined provably-safe class.
- No LLM in detection or in the apply authority — drafting only.
- No new review UI framework — extend the existing action queue + dashboard.
- No retraining of local models; threshold/rule/noise tuning only.
- No change to the live hot-path tasks themselves.

## 11. Open defaults (chosen, override if you disagree)
- Loop cadence: **nightly**, after the existing sweeps.
- Auto-approve £ ceiling: **£250 impact**, deterministic-only, widens as the benchmark proves out.
- Digest size: **top 10 by £** per night.
- Dead-rule threshold: **no match in 90 days**.
