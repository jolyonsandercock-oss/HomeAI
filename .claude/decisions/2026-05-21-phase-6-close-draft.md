# ADR — Phase 6 close (DRAFT, pending U151 sign-offs + U154 dress rehearsal)

**Date:** 2026-05-21
**Status:** Draft. Becomes "Decided" after:
  1. U151 T4 + T6 land (service migration + quota hard-mode flip)
  2. U154 T4 completes (1-staff dress rehearsal week)
**Supersedes:** N/A — phase boundary.

---

## What Phase 6 set out to do (per 2026-05-21-phase-6-kickoff ADR)

Operational close-the-loop: take the guardrails Phase 5 built (Presidio,
LiteLLM, quota, RLS roles) and ship the *operational outputs* — invoice
matching, mortgage coverage, dashboard surfaces — to the point where staff
can use them daily.

## What shipped

### Stability (U146, U151)
- 4 pipelines audited; 2 noOp-skip / 0-rows-returned bugs patched
  (Report Ingestion via Idempotency Check fix; Invoice Pipeline via
  Has-Attachment IF). 1 Haiku-parse-fail bug patched (Nanny).
- 18 untracked migrations recovered to git (V159-V177 spanning U138-U145).
- Realm pivot completed (V165 narrow applied; 464 CHECK constraints all
  allow `personal`, 0 still on `family`).
- System auto-pause loop closed; selftest 50 PASS / 0 FAIL.

### Security (U147)
- V177 applied to live; trading_role / personal_role / owner_role created.
- Pen-test green on `emails` + `vendor_invoice_inbox` — RLS isolates
  perfectly under role × realm combinations.
- Authelia FQDN forward_auth fully working at
  `https://jolybox.tailc27dff.ts.net/`.
- Consumer mapping documented (`.claude/plans/u147-consumer-mapping.md`).
- ⏸ Service connection-string migration awaiting sign-off.

### Cost gateway (U143, U144, U148)
- ai_usage extended with business_priority + capability_tag + cost_gbp.
- quota_allocations table with shadow/hard enforce_mode.
- 7d shadow audit: zero would-block events at any tier; peak utilization
  23.7%; total spend £0.47/week.
- ⏸ Hard-mode flip awaiting sign-off.

### Operational surfaces (U132, U133, U134, U135, U149, U150)
- All 81 query_whitelist slugs surfaced via dashboard API.
- Frontend pages exist at `/staff`, `/restaurant`, `/tasks/cashup` and
  consume live slugs.
- Tide times scrape + ingest (27 future rows).
- Bank holidays one-shot from gov.uk (12 holidays).
- Mortgage statement gaps slug live (7 loans, 21 missing quarters across
  3 active loans — drives the in-person packet).
- 2 new slugs: `tides_next_7d`, `bank_holidays_next_90d`,
  `mortgage_statement_gaps`, `audit_log_by_actor_7d`.

### Staff-readiness prep (U153, U154)
- audit_log gains `actor_user` / `actor_role` / `actor_ip` columns (V181).
- `/api/whoami` endpoint for diagnostic verification of Authelia headers.
- Perf baseline: every endpoint < 2s on inside-tailnet; most < 50ms.
- Runbook at `docs/runbook-when-it-breaks.md` covering 10 likely failure modes.

### Cost optimization audit (U155)
- 30-day spend: £0.69 across 255 calls (sub-£1/month operational scale).
- Highest cache opportunity: CAP_INVOICE_EXTRACT (43k-token prompts, 0% cache hit) — defer until volume justifies.
- Tier ceilings 5-10× above peak usage; no tuning needed.

## Gating criteria — were they met?

| criterion | target | actual | verdict |
|---|---|---|---|
| Selftest passes | 50 PASS / 0 FAIL | 50/0 (some runs 49/1 WARN) | ✅ |
| No auto-pause in last 24h | 0 pauses | (in flight, pending observation) | ⏳ |
| RLS isolation confirmed | 0 cross-realm leaks | 0 (pen-test green) | ✅ |
| All slugs queryable | 81 active live | 81/81 live | ✅ |
| Mobile-usable UI | every page works on phone | (pending Jo's eyes — U152 polish phase) | ⏳ |
| Per-staff identity | each action audit-logged | infrastructure ready; needs accounts (U153) | ⏳ |
| Dress rehearsal complete | 1 staff member uses system 1 week | (pending) | ⏳ |

## Pending Jo sign-offs (block "Phase 6 closed" verdict)

1. Service connection-string migration (per `.claude/plans/u147-consumer-mapping.md`)
2. Quota hard-mode flip (per `.claude/audits/u148-shadow-7d.md`)
3. Authelia user accounts for 2 test staff
4. Dress rehearsal staff member selection
5. In-person packet items (mortgage scans, Trail base URL, review URLs, Dojo CSVs, Vault rotation check)

## Recommended Phase 7

Once Phase 6 closes:

**Phase 7 — revenue-side close-the-loop**. Phase 6 covered cost (invoices → matched → categorised). Phase 7 covers revenue: bookings → covers → cash → recognised → reported. Highest £ value. Builds on the existing operational surfaces.

Phase 8+ candidates:
- Personal realm catch-up (postponed)
- Multi-property scaling pattern
- Customer-facing surfaces (booking widget, guest portal, breakfast pre-order)

## Risk register

- **Pipeline pattern regressions** — three pipelines patched, but the noOp-skip / 0-rows pattern could appear in future pipelines. Mitigation: runbook §2 covers manual recovery; threshold at 20 (down from 200 emergency, will revert to 5 after U151 lands).
- **V165 narrow rollback** — `'family'` no longer accepted; if any external system tries to write that value, error. Mitigation: 24h observation showed zero writes.
- **Quota hard-mode false-blocks** — flip might block legitimate calls. Mitigation: 7d audit showed zero would-blocks; per-tier rollback is one-line UPDATE.
