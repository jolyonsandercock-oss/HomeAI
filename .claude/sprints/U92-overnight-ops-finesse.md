# U92 — Overnight ops finesse (operations / stability / data integrity / UX)

**Prereqs**: U86–U91 shipped. Stretch is locked — no new feature ground until this batch lands.

**Realm**: cross-cutting.

**Remote-doable**: ~95% — only T2 nudge timing is Jo-dependent.

**Why this sprint exists**: Jo's locking stretch and focusing on the operational core. Five threads:
1. Pull email + invoice history back to **400 days** in suitable batches.
2. Re-benchmark **local Qwen vs Haiku** now that local OCR + line-item pipeline are in place.
3. **Audit the percentage logic** that the dashboard surfaces (labour %, GP %) — get every formula validated end-to-end.
4. **Business logic review** for the daily-reconciliation user journey (cash count submit, till variance, manager-action flow).
5. **Tasks-from-yesterday's-emails** surfacing — close the loop on email-extracted task queue.

Parked items: Land Registry deeds, Xero support chase (defer indefinitely; not blocking).
Deferred: NatWest CSV prompt → tomorrow AM via Telegram.

**Overnight-autonomous**: yes — every track is autonomous; surfaces decisions to Jo via Telegram where input is genuinely needed.

## Tracks

### T1 — Park Land Registry + Xero in the U90 packet (~5 min)

**Build**:
- Edit `audits/2026-05-15-jo-checklist.md`: move LR + Xero sections to a "Parked indefinitely" appendix. Update time estimate from 75 min → 50 min.

**Acceptance**: packet shows revised time + parked items clearly labelled.

---

### T2 — Schedule NatWest CSV prompt for tomorrow AM (~10 min)

**Build**:
- Add a one-shot reminder via `scripts/u92-nudge-natwest.sh` invoked from cron at 09:00 tomorrow. Telegrams Jo with the exact account numbers + the import command for each.
- Use `at` if available, otherwise a one-line crontab entry that self-removes after firing.

**Acceptance**: Tomorrow at 09:00 BST, Jo receives a single Telegram message listing the four NatWest accounts + paste-able commands.

---

### T3 — U89 deferred items: T2/T7/T8 (~90 min)

**Build**:
- **T2 view-deps graph** (`docs/views.md`): parse `pg_depend` for every view, output mermaid + dependency tree. Limit graph to top 30 most-referenced views to keep readable.
- **T7 memory hygiene** (`audits/2026-05-16-memory-hygiene.md`): every `feedback_*.md` and `project_*.md` in `/home/joly/.claude/projects/-home-joly/memory/` must be listed in MEMORY.md. Resolve `[[wiki-link]]` references and flag dangling. Trim any obsolete entries.
- **T8 AGENTS.md vs reality** (`audits/2026-05-16-agents-md-drift.md`): grep AGENTS.md for path/script/table references; verify each exists.

**Acceptance**: three audit/doc files produced; obvious drift fixed inline; substantive drift surfaced for Jo.

---

### T4 — Email backfill to 400 days (~45 min)

**Build**:
- Current oldest `events.email.received` = 2026-05-06 (≈9 days). Target: 400 days = back to ~2025-04-12.
- Run `scripts/u29-vendor-invoices-backfill.sh 450` (450 to overshoot the 400d target by a buffer) followed by additional broader-query passes for the `info@`/`admin@` aliases.
- Batch the Gmail API hits: 100 stubs per query, sleep 5s between, log per-batch counts to `/home_ai/logs/u92-email-backfill.log`.
- Idempotency-key on each insert means re-runs are no-ops.

**Acceptance**: `events.email.received` oldest date ≤ 2025-04-12; backfill log shows N batches with cumulative counts.

---

### T5 — Invoice backfill to 400 days + OCR (~60 min)

**Build**:
- Currently `vendor_invoice_inbox.extracted` covers 2025-06-01 → 2026-05-15 (≈349 days). Need ~60+ more days of history.
- Run `u34-invoice-backfill.sh 450` to expand the alias-driven backfill.
- For newly-ingested rows: trigger the U61 line-extractor + the U70 mortgage parser to refresh per-row state.
- For rows where the PDF is in Paperless but lines weren't extracted: enqueue + run.

**Acceptance**: `vendor_invoice_inbox` oldest ≤ 2025-04-12. New rows from this backfill triaged via the same bulk-classify pattern as U76 (Xero/SaaS/notification heuristics).

---

### T6 — Qwen vs Haiku benchmark with local OCR (~60 min)

**Build**:
- Current state: `u49-bench-extractors.sh` + `u61-line-item-bench.sh` + `u70-ocr-bench.sh` exist.
- Re-run `u61-line-item-bench.sh` with three model configs: Haiku (baseline, current), Sonnet (over-spec baseline), qwen2.5:7b (local).
- Per-config metrics: line accuracy %, total-validation %, tokens used (or local CPU/GPU s), cost estimate.
- Output: `audits/2026-05-16-qwen-vs-haiku-bench.md` with a single verdict ("Qwen approaches Haiku within X% / does not" + recommended next action).

**Acceptance**: bench report ranks Qwen against Haiku for invoice-line extraction; cost-per-1000-invoices in £ included.

---

### T7 — Percentages audit (labour %, GP %, etc.) (~75 min)

**Build**:
- Script `scripts/u92-audit-percentages.sh`. For each surfaced percentage on `/finance`, `/m`, `/economics`, `/dojo`:
  - Find the formula in main.py / v_* view.
  - Trace the numerator + denominator back to source data.
  - Confirm period scoping (today's date vs current week vs YTD).
  - Validate against a hand-computed sanity check on a known recent day.
- Output: `audits/2026-05-16-percentages-audit.md`. Flag any formula that:
  - Uses gross instead of net (or vice versa) inconsistently
  - Includes/excludes wrong entity (e.g. mixing cafe into pub GP)
  - Has wrong period boundary (e.g. counts arrivals from yesterday)

**Acceptance**: every dashboard percentage traced + validated. Issues filed as `mart.exceptions` of `kind='pct_logic_drift'` if confirmed wrong.

---

### T8 — Business logic review for cash-count + daily reconciliation (~45 min)

**Build**:
- User journey: Jo submits cash count via `/m` → goes into `till_reconciliation` → variance computed → exception raised if > £5.
- Audit:
  - Does the submit endpoint accept all required fields? (z_reading, card_total, cash_counted, float_returned, expected_cash optional)
  - Where does `expected_cash` come from? If user enters it, fine. If auto-computed (TouchOffice net + Caterbook?), where's the formula?
  - Does the variance trigger surface to `/recon` + Telegram?
  - Daily reconciliation pipeline: u67 L1 daily totals → u68 L2 surveillance → u69 morning digest. Each step still on cron + still firing clean?
- Output: `audits/2026-05-16-cash-recon-flow.md` with an end-to-end diagram + per-step health flag.

**Acceptance**: report identifies any broken/missing link in the daily flow. Concrete fixes filed as follow-up sprint or shipped inline if trivial.

---

### T9 — Yesterday's email-tasks open queue (~20 min)

**Build**:
- `/api/email-tasks/open` exists. Pull current open list. Group by sender + age.
- Surface to a Telegram message: top 5 highest-priority (by `extract_priority` if available else by age) with reply-suggestion or "Resolve in chat" action.
- Update `/m` Email tile to show this count explicitly.

**Acceptance**: Telegram sent with summary. If Jo doesn't respond by tomorrow 09:00, the prompt is included in the NatWest nudge.

---

### T10 — Recommendations + stretch lock (~30 min)

**Build**:
- Document `audits/2026-05-16-stretch-lock-recommendations.md`:
  - What we should stop building (anything not in operations/stability/data-integrity/UX).
  - What we should accelerate (likely: UX restructure once Ultraplan returns; cash-recon hardening).
  - The Top 5 risks remaining (with mitigation per item).
  - Locked next-30-days roadmap.

**Acceptance**: recommendations doc lands. Jo reviews + locks in his next session.

---

### T11 — Commit + summary (~10 min)

**Build**:
- Commits in logical chunks (one per major track or two-three small bundles). Each references `U92`.
- Final Telegram: end-of-overnight summary listing every track's outcome.

**Acceptance**: working tree clean; STATUS.md regenerated.

## What this sprint does NOT do

- Does **not** ship new functionality. Audits + bulk-data-pulls + bench + business-logic-review only.
- Does **not** unlock Land Registry / Xero / Authelia FQDN / Vault auto-unseal — those stay on Jo's in-person packet.
- Does **not** flip the postgres-superuser → homeai_pipeline migration (still parked from U87).

## Follow-on sprints

- **U93** — fix-up actions emerging from this audit batch (likely: percentage corrections + cash-recon hardening + UX prep based on Ultraplan output).
- **U94+** — strict operations focus; UX restructure execution post-Ultraplan.
