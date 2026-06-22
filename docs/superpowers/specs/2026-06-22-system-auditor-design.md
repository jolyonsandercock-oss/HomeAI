# System Auditor — Design Spec

**Date:** 2026-06-22
**Status:** Design (awaiting review → implementation plan)
**Author:** Jo + Claude (brainstormed 2026-06-22)

## 1. Purpose & context

A nightly, **mostly-deterministic** sweep that measures the system's data-integrity
(the *'what'*) and information-architecture (the *'how'*) drift, and folds a triaged
summary into the daily morning brief. It is the standing antidote to the architecture
map's stated meta-risk: *"unmanaged drift across a hybrid nobody fully measures."*

This is **phase 1 of two**. Phase 2 is the on-demand **change-time reviewer**, which
reuses this phase's sensor layer. Building the auditor first constructs that shared
layer and establishes a baseline of *current* drift.

**Design stance (non-negotiable):** monitoring is deterministic (SQL / scripts /
existing invariant gate). The LLM does exactly one job — **triage** the deterministic
findings into a readable digest. It never invents numbers (the `data-integrity` rule).
No always-on LLM. No auto-remediation.

## 2. Non-goals (YAGNI)

- No web UI / dashboard page (findings land in the brief + a table).
- No real-time / streaming. Nightly only.
- No auto-fix. The auditor **reports**; humans/other tools act.
- Not the reviewer (phase 2) — but the check functions are written so the reviewer can call them per-diff.

## 3. Architecture

```
nightly cron (~05:30)
  └─ scripts/u-system-auditor.py  (orchestrator)
       ├─ run each CHECK independently → Finding{...}      (deterministic)
       ├─ diff vs last run (fingerprint) → new/changed/resolved
       ├─ persist findings  → cognition.agent_findings
       ├─ record_pipeline_run('system_auditor', ...)       (dogfoods the registry)
       ├─ ONE claude_call triage → ranked digest (HTML section)   (LLM, grounded)
       │     └─ fallback: deterministic plain digest if LLM unavailable
       └─ heartbeat → cron log (cron-health observability)

morning brief (u109-daily-reality.py)  [decoupled]
  └─ section('System audit', n_active, body)  reads cognition.agent_findings
       └─ if no fresh auditor row: render "audit: no fresh data" (never breaks the brief)
```

**Decoupling:** auditor *writes* findings to a table; the brief *reads* them. Neither
can break the other. If the auditor dies, the brief shows "no fresh audit"; if the brief
is dormant, findings still persist + high-severity still pages Telegram.

## 4. Check catalogue (comprehensive v1)

Each check is an **independent unit**: `check_<name>(ctx) -> Finding`, separately
testable, one failing check never aborts the sweep. `Finding = {check_id, lens,
severity (ok|info|warn|fail), title, detail, value, fingerprint}`.

### Integrity — the 'what'
| check_id | source | fail/warn condition |
|---|---|---|
| `revenue_reconciliation` | `mart` revenue-recon (V275) | any month status ≠ `reconciled` |
| `bank_freshness` | `max(transaction_date)` | newest txn older than SLA (e.g. 7d) |
| `bank_dedup` | exact-dup partition count | > baseline (currently 5) |
| `invoice_categorisation` | `ops.live_state()` | coverage % drops vs last run / below floor |
| `invoice_uncategorised_gbp` | `ops.live_state()` | surfaced figure (info; warn if rising) |
| `events_overflow` | `events_overflow` rowcount | > 0 (partition gap leak) |
| `dead_letters` | `dead_letter` unresolved | > 0 |
| `pipeline_freshness` | `ops.check_freshness()` / `pipeline_runs` | any registered pipeline past SLA |

### Architecture — the 'how'
| check_id | source | fail/warn condition |
|---|---|---|
| `invariants` | `audit-invariants.py --check` vs baseline | any NEW finding (reuses existing gate) |
| `taxonomy_vocabulary` | invoice `category_canonical` + sales dept | values outside canonical `{bar,kitchen,cafe,rooms,overhead}`; flags a "4th vocabulary" |
| `realm_coverage` | RLS tables / routes | rows in realm-scoped tables with NULL realm; best-effort v1 |
| `guc_drift` | `RLS_ENFORCE_SET_ROLE` flag + GUC defaults | missing `app.current_entity/realm` defaults (per the SET-ROLE-drops-defaults gotcha) |
| `untracked_load_bearing` | crontab/compose/flock refs vs `git ls-files` | a referenced script/file is git-untracked (today's playwright-tools class) |
| `n8n_cron_reconciliation` | n8n active workflows + crontab vs pipeline registry | runner with no registry entry, or registry entry with no runner (the meta-risk) |

`realm_coverage` and `n8n_cron_reconciliation` are the hardest; scoped as **best-effort
v1** (a defined query each), refined later — not a reason to delay the harness.

## 5. Data model

Reuse `cognition.agent_findings` (V272). Mapping: `agent='system-auditor'`,
`kind=check_id`, `subject=title`, `detail=detail+value`, `verified=true` (deterministic),
`evidence=the query/figure`, `realm='owner'`. Auto-resolve via `supersedes_id` — a new
run's finding for a `check_id` supersedes the prior one.

**Optional small migration** (cleaner dedup/rendering): add `severity text`,
`status text` (`firing|resolved`), `fingerprint text unique-ish`, `last_seen_at`. If we
skip it, severity/status are encoded in `kind`/`detail` (workable but uglier). Decision
deferred to the plan; lean toward the migration.

## 6. LLM triage

Single `claude_call` (Haiku, retry wrapper). Input: the structured findings only.
Output: severity ordering + a 3–6 line "so what" + an HTML body for the brief section.
**Prompt is constrained to the supplied findings** — it may summarise/prioritise, never
introduce a number not in the input. **Fallback:** if the call fails/over-budget, emit a
deterministic plain digest (sorted by severity). The auditor must work with the LLM off.

## 7. Delivery

- **Primary:** `u109-daily-reality.py` gains `out.append(section('System audit',
  n_active, body))`, reading the latest `system-auditor` findings from
  `cognition.agent_findings` and rendering with existing `STY` (red `fail` / amber
  `warn` / green `ok`, matching the colour convention).
- **⚠ Dependency/risk:** `u109` is **not currently in cron** and has no n8n trigger I
  could find — it may be **dormant**. The fold-in only delivers if the brief runs.
  **Action in the plan:** confirm/revive u109's schedule, OR (decided here) the auditor
  **independently pushes `fail`-severity findings to Telegram** so nothing high-severity
  depends on the brief being alive.

## 8. Cadence, dogfooding & observability

- Cron `30 5 * * *` (before the brief). Heartbeat to its cron log (cron-health).
- Calls `ops.record_pipeline_run('system_auditor', ...)` every run — **this is the first
  real producer for the empty `ops.pipeline_runs` registry**, a stated gap.

## 9. Error handling & isolation

- Each check in its own try/except → a `fail` Finding for that check on error; sweep
  continues. One bad check never blanks the audit.
- LLM failure → deterministic digest (§6).
- Brief read failure → "audit: no fresh data" line (§3).
- Auditor is read-only on business data; only writes to `cognition.agent_findings` +
  `ops.pipeline_runs`.

## 10. Testing

- Per-check unit test: seed a known state → assert Finding shape/severity. Checks are
  pure functions of `(conn/ctx)`, so each tests in isolation.
- Orchestrator smoke test: dry-run (`--no-write --no-llm`) against the live DB → prints
  findings, asserts no exception, all checks return a Finding.
- u109 section test: given seeded findings, asserts the section renders + degrades
  gracefully when empty.

## 11. Components / files

- `scripts/u-system-auditor.py` — orchestrator (asyncpg + subprocess for git/invariants).
- `scripts/auditor/checks_integrity.py`, `scripts/auditor/checks_architecture.py` — the
  check functions, one per `check_id`, independently testable.
- `scripts/auditor/digest.py` — triage prompt + deterministic fallback formatter.
- (optional) `postgres/migrations/V2xx__agent_findings_severity.sql` — §5 columns.
- `u109-daily-reality.py` — add the audit section (small, additive).
- crontab line + cron-health (heartbeat already covered by the pattern).
- tests under `tests/auditor/`.

## 12. Dependencies, risks, open questions

- **u109 may be dormant** (§7) — confirm first; Telegram fallback de-risks it.
- `ops.pipeline_runs` is empty / `ops.check_freshness` coverage may be partial — the
  `pipeline_freshness` check is only as good as the registry; auditor populating runs
  starts to fix that.
- `realm_coverage` / `n8n_cron_reconciliation` queries need definition (best-effort v1).
- `agent_findings` migration: do it or encode in existing columns (§5).

## 13. Build order (within the auditor)

1. Orchestrator + Finding model + `cognition.agent_findings` persistence + heartbeat + `record_pipeline_run`.
2. The **reuse** checks (live_state, invariants, reconciliation, freshness, dead-letters, overflow, dedup).
3. The **new** checks (taxonomy, untracked-load-bearing) — high value, today's-gap coverage.
4. LLM triage + deterministic fallback.
5. u109 section + Telegram high-severity fallback.
6. The **hard** checks (realm_coverage, guc_drift, n8n↔cron reconciliation) — best-effort.
7. Tests throughout.
