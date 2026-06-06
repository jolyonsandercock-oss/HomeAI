# Review Response — system-review.md (instruction #260)
**Reviewer:** Claude · **Date:** 2026-06-06

Solid, well-prioritised review. Status of each item against the live system today:

## Already resolved (this session, 2026-06-06)
- **A7 / P2 "No Cron Health Monitoring"** — DONE. Built `scripts/cron-health-check.py`
  (*/30): derives a freshness tolerance per crontab job, raises a self-resolving
  `system_alerts` CronStale row when any job goes stale. This is exactly the
  "TouchOffice backfill silently stalled for weeks" class — and it already caught the
  2026-05-30 cron rot (u95/u50-stale-ack/u62/u68/vault-renewer all dead, now fixed).
- **Part B (Invoice pipeline)** — substantially addressed. The pipeline was reconciled:
  the deactivated P2 was confirmed superseded by the u95-harvest → u35-extract →
  u36-Haiku chain → `vendor_invoice_inbox`; the harvest cron (broken since 05-30) was
  fixed; Paperless sync/classify (u62/u68) restored. B3's verdict (single GPU workhorse
  + Claude escalation, no 3-model cascade) and B5 (Qdrant over-engineered — it's
  provisioned but unused; real retrieval is Postgres `search_vectors`) both confirmed
  correct against the live system.

## Still valid — recommend as the next hardening sprint
- **A1 (P0) API write-auth** — `/api/breakfast/submit`, `/api/dinner/remind`,
  `/api/feedback/line` still unauthenticated. Genuine. Distinct from the RLS-role
  migration (U249) — that's DB-layer; this is HTTP-layer. Both needed.
- **A2 (P0) missing indexes** — `entities(realm)`, `ai_usage(entity_id, timestamp)`.
  30-min quick win; do alongside A1.
- **A4 (P1) realm-isolation gaps** — `snag_inbox`, `vendor_category_rules`,
  `card_statements`, etc. Fold into U249.
- **A3 (P1) emails FTS**, **A6 slug validation**, **A5 CSP/rate-limit**, **A8 bundle
  splitting**, **B4 idempotency = (supplier, inv_no, source_file_hash)** — all valid,
  lower urgency.

## Verdict
No correction needed to the review's analysis. Two of its biggest items (cron health,
invoice pipeline) are now done. The remaining security items (A1 auth, A2 indexes, A4
realm) are the right next hardening sprint — they pair naturally with U249.
