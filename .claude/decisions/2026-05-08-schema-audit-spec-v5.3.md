# Schema audit: init-db.sql vs SPEC v5.3 §3.2

**Date:** 2026-05-08
**Scope:** D3 of long hands-off sprint
**Method:** Naive Python parser extracts CREATE TABLE column lists from
both sources, computes set-difference per shared table.

## Findings

### Tables in SPEC but NOT in init-db.sql (4)

All Phase 2/3 — no Phase 1 action required:

| Table | Phase | Note |
|---|---|---|
| `workforce_shifts` | 2 (HR module) | Per SPEC §11+ Ghost Shift Detector |
| `guest_history` | 2/3 (Hospitality) | |
| `child_milestones` | 2/3 (Family) | |
| `competitor_ratings` | 3 (BI) | |

### Column drift (4 tables, all benign)

| Table | init-db has | SPEC §3.2 snippet shows | Verdict |
|---|---|---|---|
| `accommodation_daily_reports` | `entity_id` | (omitted) | **SPEC omission** — table is entity-scoped per §3.3 RLS policy |
| `epos_daily_reports` | `entity_id` | (omitted) | Same — RLS-scoped, needs entity_id |
| `till_reconciliation` | `entity_id` | (omitted) | Same |
| `model_scores` | `score_date` | (omitted) | SPEC omission — score_date is a natural query dimension |

The drift is SPEC-side: the §3.2 table snippets omit columns that §3.3 RLS
policies require (`entity_id`). The implementation is correct.

### Action

None for Phase 1. When the SPEC is regenerated next time, suggest a
mechanical pass that ensures every table referenced by an `entity_isolation`
policy has `entity_id INT REFERENCES entities(id)` in §3.2.
