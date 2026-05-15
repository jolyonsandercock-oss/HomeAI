# Audits index

Generated outputs from the U86 audit sprint (and successors). Files are dated
`YYYY-MM-DD-<topic>.md`; latest run wins.

## 2026-05-15 — U86 data-integrity sweep

| Track | Output | Headline |
|---|---|---|
| T1 bank-data coverage | `2026-05-15-bank-coverage.md` | 13 accounts; 2 zero-ever (15 ATR Trading Dojo settlement, 14 RBS predecessor card); 3 stale > 30d |
| T2 FK-orphan scan | `2026-05-15-fk-orphans.md` | 452 FKs checked, 0 orphans, schema clean |
| T3 idempotency-key audit | `2026-05-15-idempotency-audit.md` | UNIQUE-constraint-tagged tables all populated, no convention violations |
| T4 schema drift | `2026-05-15-schema-drift.md` | (generating — long-running scratch-DB replay) |
| T5 dead-letter triage | `2026-05-15-dead-letter-triage.md` | event-table failure buckets summarised (0 buckets — clean) |
| T6 missing-data hunter rerun | `2026-05-15-missing-data-summary.md` | 9 open ghost_shift_day (Q2 2026 days); 0 open to_scrape_gap / dojo / till |

## Action queue for follow-on sprints

- **U87 — Secure** acts on:
  - T2: orphan list is empty — no action needed, schema is clean.
  - T4: any drift detected → catch-up migration (or document each as intentional).
- **U88 — Fix and forget** acts on:
  - T5: replay-safe failure buckets get queued for retry.
  - T1: account #15 (Dojo settlement) wants the U72 onboard-48885517 CSV.
- **U90 — In-person packet** acts on:
  - T1: stale-account list (3 accounts) → Jo confirms paper statements or NatWest CSV mining.
