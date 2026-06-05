# Security review — 2026-06-04 (U235 overnight hardening)

Reviewer: Claude (opus-4-8). Scope: U235 cultural-memory changes + full build-state
self-test + RLS/superuser/backup audit. Read-only audits via existing
`scripts/u87-audit-*.sh`; safe fixes applied inline; risky fixes documented only.

## Self-test
`scripts/selftest.sh`: **49 PASS / 1 WARN / 1 FAIL**. Only FAIL = "nightly backup
ran <24h" (now resolved, see below). build-dashboard healthz PASS post-rebuild;
sanitiser + P2 invoice fixtures PASS.

## Findings

### 🔴 Critical (highest priority — NOT fixed tonight; too risky to do blind)
1. **All backend services connect as the `postgres` superuser** — build-dashboard,
   google-fetch, bot-responder, playwright (`PG_DSN=…postgres:…`). Superuser
   **bypasses RLS entirely**, so realm/entity isolation is enforced ONLY on the
   frontend path (which uses `homeai_readonly`) and wherever a query filters realm
   explicitly. The realm-isolation model is effectively advisory for every backend
   service. Fix = migrate services to `homeai_pipeline` (DML) / `homeai_readonly`
   (SELECT) per `scripts/u87-audit-superuser-usage.sh` categories, keeping superuser
   only for DDL/migrations. High effort + breakage risk → deliberate task, not
   overnight. Report: `audits/2026-06-04-superuser-audit.md`.

### 🟡 Warning
2. **380 tables have realm/entity columns but RLS off** (`audits/2026-06-04-rls-coverage.md`).
   Mostly `mart.*` rollups, `events_*` partitions, and reference data (tide_times,
   bank_holidays, business_calendar) — many legitimately open. Needs a triage pass for
   the genuinely sensitive ones. NB: while services run as superuser (finding 1),
   enabling RLS here changes nothing for them — fix finding 1 first.
3. **Backup schedule was missing** (lost in the mid-May crontab reset). FIXED:
   re-installed `0 3 * * *` cron + ran a fresh snapshot (`b2c6e54f`). Residual: the
   run exits 3 because 4 root-owned scripts (`vault-watchdog.sh`,
   `u35-manual-data-freshness.sh` + `.bak`s) are unreadable by the `joly` cron user —
   critical data (DB dump, n8n/vault volumes) IS captured. Recommend root-owned cron
   or a restic `--exclude` for those files.

### ℹ️ Info / false positives
4. `xero_bills` / `xero_bill_lines` flagged 🔴 "RLS on, no isolation policy" by the
   audit — **false positive**: their policies DO filter on `app.current_realm`; the
   audit heuristic only matches the name `realm_isolation`.
5. Entropy scan of all files changed this session: **clean** (no secrets).

## Hardening APPLIED this session (verified)
- `/api/research/ask` now **realm-filters results explicitly** (FTS + dense + passage
  resolution) — previously returned all realms regardless of `X-Realm` because of
  finding 1. Verified: work-realm caller returns 0 personal passages.
- **RLS added** to `search_vectors` + `email_rag_chunks` (V227/V225) — defence-in-depth
  for the non-superuser (frontend) path. Verified per-realm.
- **Rule-4 gap closed**: `v_research_corpus` now uses the sanitised `email_chunk`
  corpus; the raw whole-`email` branch (raw `body_text`) was dropped.
- Backup schedule restored + fresh snapshot.

## Decision
Ship the U235 RAG work (realm-safe). Treat finding 1 (services-on-superuser) as the
next security sprint — it is the root cause that makes most RLS advisory. Do not
blanket-enable RLS (finding 2) before finding 1, and not blind/overnight.
