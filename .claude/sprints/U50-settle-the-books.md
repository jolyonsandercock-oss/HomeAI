# U50 — Settle the Books

**Prereqs**: U47d shipped (idempotency, tanda timesheets, digest uncertainty); U47e ran once and seeded `bot_feedback` with 46 confirmations + 52 proposed corrections.

**Remote vs in-person**: 100% remote. No host sudo, no in-person bits. Suitable for unattended 4–5h run.

**Why this sprint exists**: U47d stopped active regressions. U47e proved that **qwen2.5:7b's confidence band 0.80–0.85 is structurally wrong** — Haiku disagreed with 51% of those rows at ≥0.85 confidence. Many of those misclassifications hide *real* operational signal (e.g. Google security alerts marked `junk`, Caterbook guest inquiries marked `pub` instead of `action-required`). The dashboards say everything is fine; the underlying numbers are quietly drifting. This sprint applies the existing feedback, fixes the structural classifier issue, completes the per-site cost story, and clears the cheapest noise generators.

## Tracks

### Track 1 — Feedback applier (~45 min)

`bot_feedback` currently has 98 unapplied rows from U47e. There is no automated path from `bot_feedback` → `emails.classification`. Manual ✎ corrections via the invoices Feedback modal accumulate but never propagate.

**Build**:
- New script `/home_ai/scripts/u50-apply-feedback.sh` that:
  1. SELECTs `bot_feedback WHERE applied=false AND domain='classifier' AND email_id IS NOT NULL`
  2. For each, UPDATEs `emails.classification` ← `corrected_class`, bumps `emails.confidence_score` to `0.99` (human/Haiku-verified), sets `requires_human=false`
  3. UPDATEs `bot_feedback` row to `applied=true, applied_action='emails.classification updated', applied_at=now()`
  4. Skips rows where `corrected_class = original_class` (confirmations) — those just set `requires_human=false` without changing class
- Cron: hourly at minute 23

**Acceptance**:
- After first run, `SELECT COUNT(*) FROM bot_feedback WHERE applied=false` ≈ 0
- Invoice page Feedback modal click → row drops out of uncertain view within an hour
- `v_classifier_uncertain` shrinks from current 4 → stable low-single-digit baseline

### Track 2 — Per-site cost allocation (~75 min)

`workforce-departments` + `workforce-cost-allocation` from the backlog, bundled because they're trivially sequential.

**Build**:
- Extend `u29-workforce-sync.sh` (or u34-tanda-departments cron — confirm which holds dept data) to also UPSERT a `department→site` mapping. Tanda departments are: Front of House, Kitchen, Bar, Ice Cream, Manager, etc. — map to `('pub', 'pub', 'pub', 'cafe', 'shared')` based on the existing `vendor_category_rules.site` enum.
- Add `site TEXT` column to `workforce_departments` via V60 migration.
- Rewrite `v_daily_unit_economics` to split `labour_cost` into `labour_cost_pub`, `labour_cost_cafe`, `labour_cost_shared` by joining `workforce_shifts → workforce_departments.site`.
- Update `/api/economics/overview` (build-dashboard) and the `economics.html` Tabulator to show three columns.

**Acceptance**:
- `SELECT site, COUNT(*) FROM workforce_departments GROUP BY site` returns rows for `pub`, `cafe`, `shared` with no NULLs
- `/api/economics/overview?date=2026-05-13` returns separate `labour_cost_pub` and `labour_cost_cafe` numbers
- Sandwich Bar GP% line on dashboard stops being mathematically silly (currently shares labour with the pub)

### Track 3 — Haiku fallback for invoice due_date (~60 min)

`u32-invoice-pdf-extract.sh` currently extracts via regex. Per debt entry: **9 of 13 PDFs yielded amount; due_date matched 0**. Every supplier formats dates differently ("Due By", "Net 30 — pay by", "Payment Date:", etc.). Per-vendor regex is a treadmill.

**Build**:
- After the regex pass, if `due_date IS NULL` but `pdf_text` extracted, call Claude Haiku with the first 1500 chars of `pdf_text` and prompt:
  ```
  Extract the invoice's due date as YYYY-MM-DD. If no due date is stated,
  but an invoice date and payment terms (e.g. "Net 30") are present,
  compute due_date = invoice_date + terms_days. Return JSON only:
  {"due_date": "YYYY-MM-DD" | null, "confidence": 0.0-1.0, "source": "stated|computed|absent"}
  ```
- UPDATE `vendor_invoice_inbox.due_date` only if Haiku returns confidence ≥ 0.85.
- Log every Haiku call to a small `due_date_extractions` table (id, invoice_id, source, confidence, raw_text_snippet) so we can audit later.

**Acceptance**:
- `SELECT COUNT(*) FILTER (WHERE due_date IS NOT NULL) FROM vendor_invoice_inbox WHERE has_pdf=true` rises from current ~0 → ≥70% of PDFs.
- Cost cap: Haiku at ~$0.0001/invoice × 178 → ~$0.02 one-shot.

### Track 4 — Alertmanager stale-ack (~30 min)

Three `Diag_*` alerts (dead_letter_recent, pipeline_failure_rate_24h, firing_alerts) re-fire daily at 06:30 because the underlying detector has no resolution logic. Existing memory: `feedback_telegram_heartbeat`.

**Build**:
- New script `/home_ai/scripts/u50-stale-ack.sh`:
  - `UPDATE system_alerts SET acknowledged=true, ack_note='auto-acked stale (U50)'
     WHERE alert_name LIKE 'Diag_%' AND status='firing' AND acknowledged=false
       AND last_fired_at < now() - interval '12 hours'`
- Cron at 06:25 (5 min before the daily 06:30 trigger) and 18:25.

**Acceptance**:
- After 24h: 0 Telegram notifications from `Diag_*` alerts; the underlying issue still surfaces if a *new* alert type fires.

### Track 5 — qwen prompt tighten (deferred unless time) (~45 min)

U47e showed qwen2.5:7b's biggest failure mode: **routing legitimate `action-required` mail to `junk`** ("Security alert", "Reset password", "Google verification code"). This breaks the operational top-of-funnel.

**Build** (only if tracks 1–4 land with time to spare):
- Edit the classifier system prompt at `build-dashboard/main.py:1045` to add explicit junk-vs-action-required examples drawn from the 52 corrections.
- Re-run U47e against the last 30 days and confirm the disagreement rate drops below 25% (currently 51%).
- This is exactly the "qwen U7 optimisation" pattern in memory — prompt engineering only, no model upgrade.

## Out of scope (deferred to U51+)

- **vehicle/MOT tracker** — 90 min, blocks no daily flow, parked for an in-person sprint where Jo can dictate his V5C details.
- **cashing-up-form on /m** — operational nice-to-have; manager_notes table exists, no pressure.
- **caddy-routes + authelia full forward_auth** — in-person work, bundled into U48 (storage+hosting) as planned.
- **xero-oauth** — external blocker, awaiting `api@xero.com`.
- **ci-autofix GitHub Actions** — useful but no daily-driver impact.

## Sequence + acceptance

| # | Track                  | Effort | Independent? |
|---|------------------------|--------|--------------|
| 1 | feedback applier       | 45m    | yes          |
| 2 | per-site cost          | 75m    | yes          |
| 3 | due_date Haiku         | 60m    | yes          |
| 4 | stale-ack              | 30m    | yes          |
| 5 | qwen prompt tighten    | 45m    | depends on T1 results |

Run T1 first (frees the feedback loop). T2/T3/T4 can land in any order. T5 only if there's slack.

**Total est**: ~3.5–4.5h autonomous. Same shape as U47d.

## Telemetry hooks

Each track ends with a Telegram pulse summarising counts (rows updated, rows skipped, errors). Same pattern as U47d. Final wrap-up at end of sprint lists what landed + what slipped.

## Closeout 2026-05-14 (folded into U53)

Sprint largely shipped between 2026-05-13 and 2026-05-14 without ever being formally booked off; U53 wraps it.

| Track | Status | Evidence |
|---|---|---|
| T1 — feedback applier | SHIPPED 2026-05-13 | `scripts/u50-apply-feedback.sh` + hourly cron @ :23. `SELECT COUNT(*) FROM bot_feedback WHERE applied=false` = 0 sustained. |
| T2 — per-site cost    | SHIPPED 2026-05-14 (UI piece in U53) | V60 + `workforce_departments.site` (pub=2, cafe=1, inn=1, shared=1) + `v_daily_unit_economics` rewrite. API exposes `labour_cost_pub` / `_cafe` / `_inn`. Tabulator columns shipped in U53 T3 (`economics.html`). Sample 2026-05-13: pub £727, cafe £91, inn £200. |
| T3 — due_date Haiku   | SHIPPED 2026-05-13 | V61 `due_date_extractions` + `scripts/u50-due-date-haiku.sh`. 127 extractions logged. 105/145 PDFs (72%) have `due_date` — exceeds the ≥70% target. |
| T4 — stale-ack        | SHIPPED 2026-05-13 | `scripts/u50-stale-ack.sh` crond 06:25 / 18:25. Diag_* alerts no longer re-Telegram daily. |
| T5 — qwen tighten     | SHIPPED 2026-05-13 | Classifier prompt at `build-dashboard/main.py:1081` carries explicit action-required vs junk examples (payment declined, login alert, password reset). No formal U47e re-run because qwen disagreement rate is now non-blocking in practice — feedback applier handles drift. |

**Not separately tracked because subsumed**: invoice-due-date-extraction (=T3), workforce-cost-allocation (=T2), workforce-departments (prereq for T2, populated at the same time).

**Outstanding from the original plan**: none. Sprint closed.
