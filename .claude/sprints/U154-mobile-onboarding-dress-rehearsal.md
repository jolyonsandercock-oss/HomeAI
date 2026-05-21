# U154 — Mobile + onboarding + dress rehearsal

**Prereqs**: U151 (stable pipelines), U152 (UI live), U153 (per-staff RBAC).

**Realm**: `work`.

**Remote vs in-person**: T1-T3 remote. T4 requires a real staff member sitting with the system for a week.

**Why this sprint exists**: a UI that works in Chrome on desktop is not the same as a UI that works on a staff member's phone at 11pm in a busy pub kitchen. This is the last gate before broader rollout — prove one real person can use the system unsupervised before letting more in.

## Tracks

### T1 — Mobile audit + fixes (~half day)

**Build**:
- Walk every page (Work + Build + Admin) on iOS Safari + Android Chrome.
- Check: tap targets >=44px, no horizontal scroll, text legible, modals dismissible without keyboard.
- Fix the ten worst offenders.
- Add CSS `@media (max-width: 600px)` rules where needed; lean on Tailwind's responsive prefixes.

**Acceptance**: every page works on a phone for the operational happy path.

### T2 — Performance baseline (~60 min)

**Build**:
- Use `curl --resolve` + `time` to measure each page's first-paint time.
- Use Lighthouse CLI on key pages.
- Document baseline in `audits/u154-perf-baseline.md`.
- Fix any page taking >2s to first content (likely slug query optimization).

**Acceptance**: every page renders first content in <2s on 4G mobile.

### T3 — Runbook + alerts (~90 min)

**Build**:
- `docs/runbook-when-it-breaks.md` — common failure modes + first response:
  - System auto-paused → run drain script (link to `feedback_pipeline_downstream_missing` memory).
  - Telegram bot stops responding → check `Telegram Bot (commands)` n8n executions.
  - Dashboard 500s → tail `homeai-build-dashboard` container logs.
  - Postgres slow → check `pg_stat_activity` for long-running queries.
  - Cost cap reached → check `quota_status_7d` slug + which tier breached.
- Alerts checklist: Prometheus rules wired to Alertmanager → Telegram. Verify each fires synthetically.

**Acceptance**: every alert reaches Jo's Telegram within 60s of firing; runbook covers the 8 most likely failure modes.

### T4 — Dress rehearsal: 1 staff member, 1 week (~7 days observation)

**Build**:
- Pick the trusted staff member (Jo's choice — likely Helen).
- Provision account (`manager` role) via T1 of U153.
- 30-min sit-down session: walk through the daily-driver flows. Record what's unclear.
- Daily check-in (Telegram-friendly) — 1 question: "anything confusing today?"
- Log all issues to `audits/u154-dress-rehearsal-issues.md`.
- Fix blockers same-day; tweaks accumulate to a polish list.

**Acceptance**:
- Staff member can complete daily tasks unsupervised by end of day 3.
- Zero data-loss incidents.
- Zero "ohno" moments (RLS leak, wrong data, broken state).

### T5 — Go/no-go decision (~30 min, end of T4)

**Build**: a written go/no-go memo (`audits/u154-go-no-go-2026-MM-DD.md`) covering:
- Issues found + which were blocking vs polish.
- Performance against the 4 gating criteria from the Phase 6 ADR.
- Recommended next step: full rollout / extended dress rehearsal / specific blockers to fix first.

**Acceptance**: clear yes/no on broader rollout; if yes, a date for next staff member to onboard.

## Done criteria

- Mobile audit complete; every page passes the happy-path test on phone.
- Performance baseline documented + any >2s page fixed.
- Runbook covers the 8 likely failures.
- Dress rehearsal completes with no data-loss / no permission leak.
- Go/no-go memo written.

## Risk

Low/Medium. The technical risks are mostly bounded; the unknowns come from how a real human uses the system in real conditions. Mitigation: 7-day observation window catches everything from "kitchen wifi drops randomly" to "can't see the screen in sunlight".

## Outcome trigger for U155

Phase 6 close. Once the system is staff-ready, optimization is the right next focus.
