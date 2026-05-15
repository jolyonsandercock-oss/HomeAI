# Stretch lock — recommendations + next-30-days roadmap

Generated 2026-05-15. Output of U92 T10.

## Where we are

| Dimension | State |
|---|---|
| **Data ingest** | Email pipeline working back to **2025-02-24** (446d). Invoice pipeline depth identical. Mortgage backbone forensically rebuilt + auto-parsing on new scans. |
| **Stability** | Critical-listener live (Telegram on critical exceptions). Cron health audited. Watchdog suppression widened to 2h. |
| **Data integrity** | FK schema clean (0 orphans across 452 FKs). Idempotency conventions audited. Schema drift quantified (240 lines, deferred to a catch-up migration). |
| **UX** | Refactor plan written + handed to Ultraplan for refinement. Awaiting cloud return. |
| **Security** | RLS audit complete; entropy pre-commit hook live. Superuser→pipeline-role migration audit done (47 candidates, not migrated). |
| **AI/LLM** | Qwen 2.5:7b confirmed at 78.1% accuracy for invoice line extraction (vs Haiku 96.9%). Decision: stay on Haiku primary. |

## Lock-down — what STOPS

1. **No new functional surface area** until UX restructure ships. (Per Jo's call this session.)
2. **No more autonomous schema migrations** beyond V100 catch-up. Schema is the trust anchor; tighten not expand.
3. **No new n8n workflows.** The U88 audit confirmed the existing surface is enough; new automation goes via cron + Python + the slug pattern.
4. **No new dashboard pages** until UX restructure decides what stays.

## Top 5 risks remaining (with mitigation)

| # | Risk | Mitigation |
|---|---|---|
| 1 | **pub GP% is wrong** — hardcoded 60/40 wet/dry split in `v_daily_gp`. Real mix varies and drives wrong per-stream margin reporting. | U93 T1: replace with actual department-mix pull from `touchoffice_department_sales`. ~1h. |
| 2 | **Cash variance silently ignored** when `expected_cash` isn't entered. Today: 121 till rows, very few have a real variance computed. | U93 T2: server auto-computes expected from TouchOffice + Caterbook. ~30 min. |
| 3 | **NatWest acct #15 has zero rows** — every Dojo settlement is unmatched (104 high-severity exceptions). Blocks the U68 L3 settlement matching arc entirely. | Tomorrow's NatWest CSV nudge (already cronned). Run u72-onboard-48885517.sh after import. |
| 4 | **Schema drift** — 240 lines of live-vs-migration mismatch. Eventually a `pg_dump` restore won't reproduce production. | U93 T3: catch-up V100 migration that reconciles drift. Risk-bounded (additive only, no destructive ALTER). |
| 5 | **47 cron scripts run as postgres superuser** — bypassing RLS. If one ever leaks a sender_email into a wrong realm, no protection. | U94 (after stretch unlock): per-script migration to homeai_pipeline + SET LOCAL guards. Mechanical work, 30 min each × 47 = ~24h split across sessions. |

## Next-30-days roadmap (locked)

### Week 1 — finesse + UX intake
- ⏳ Ultraplan returns U84 UX refinement (background, no ETA from us)
- U93 ship: 4 small but real fixes (GP formula, expected_cash auto, till→exception trigger, per-session hunter)
- Daily Jo activities flow through the system (cash counts, invoice review)

### Week 2 — UX restructure begins
- Once Ultraplan's plan lands, execute Phase 1 (realm toggle + Today pages)
- Schema-drift V100 catch-up migration applied

### Week 3 — operations week
- u87 T3 role migration (15 scripts/day × 3 days)
- Cash-recon flow harden post-U93 fixes
- Bank-statement OCR for the 34 NatWest PDFs from U82 mining

### Week 4 — stability + reporting
- Add `splh` (sales per labour hour) threshold values to `ops_thresholds`
- Reporting prep: weekly summary email, monthly recon roll-up
- Whatever falls out of UX restructure week 2

## What we should NOT do (catalogued temptations)

- ❌ Build a new reporting dashboard "while waiting for Ultraplan"
- ❌ Add a "stretch" sprint with new feature ground
- ❌ Try Qwen 3 / try a new local model / re-bench OCR engines
- ❌ Migrate to a new auth system (Authelia is fine)
- ❌ Touch the SPEC.md architecture
- ❌ Refactor the slug pattern
- ❌ Add new schemas (mart/raw/staging/public is the full set)

## Backlog for "after stretch unlocks"

(Only here so we remember; not promising any of these.)

- Recipe expansion (we have 30 PLUs seeded, want top 50)
- Forecast vs actual labour
- VAT return prep automation
- Companies House sync
- Property valuation tracking (Land Registry feed)
- Vehicle MOT + insurance dashboard polish

Each of these is a quarter-day to a half-day. None is urgent.
