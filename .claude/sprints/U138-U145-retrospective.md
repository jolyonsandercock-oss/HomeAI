# U138–U145 retrospective (Phase 5 hardening run, 2026-05-18 → 2026-05-21)

Reconstructed from migration files V159–V177 and the modified services
they ship with. No standalone plan files were written at the time — this
doc fills that gap retroactively so future sessions have the context.

All migrations are in git as of 2026-05-21 (commits `4669f18`, `5ed07b0`,
`265f5cc`, `f592257`, `8a0d4cd`, `5c0d54e` ← service implementations,
`02d10c1` ← U138 frontend).

---

## U138 — Expense rollup + admin invoice drilldown
Files: V160, V161, V166, V167, V168, V169 · `services/homeai-frontend/app/admin/invoices/[id]/`, `app/api/feedback/line/`, `components/admin/{ExpenseRollup,LineRecodePopover,OrphanTile,QuotaStatusTile}.tsx` · scripts `u138-e-backfill-pilot.py`, `u138-promote-feedback-to-rules.py`.

Adds the "Accumulated expenses from emails" tile on `/app/admin` and the
per-invoice drilldown page. V161 fixes an entity_isolation RLS policy
bug on `vendor_invoice_lines`. V167-V169 build the
`department_dim` + `line_category_feedback` capture/feedback loop that
the `LineRecodePopover` component writes into; once a vendor→product
mapping has enough feedback signals,
`u138-promote-feedback-to-rules.py` promotes it to
`vendor_invoice_rules`.

## U139 — Realm rename FAMILY → PERSONAL
Files: V164, V164b, V165 (DRAFT), V176 · `.claude/decisions/2026-05-19-realm-personal-pivot.md` · build-dashboard + wa-bridge + google-fetch realm-map edits.

Three-realm vocabulary becomes **owner / work / personal**. ARE (entity
2) moves from FAMILY → PERSONAL alongside Personal + Family entities.
Operational AI hardening scope is now strictly WORK only.

* V164: widen CHECK constraints + UPDATE realm='family' → 'personal'.
* V164b: companion for partitioned-PARENT tables (V164's loop skipped them).
* V165 — DRAFT: narrows vocabulary by dropping 'family'. Do not apply
  until services confirmed not writing 'family'.
* V176: realm helpers (`set_realm`, `realm_override`) become
  personal-native.

**Known gap**: 349 declarative partition CHILD tables still have CHECK
constraints excluding 'personal'. V164b targeted relkind='p' parents
only. Inserts/updates writing 'personal' into those partitions would
fail — addressable in a follow-up V164c sweep.

## U141 — Presidio PII redaction (HARD-FAIL on cloud calls)
Files: V174 · `services/llm-router/main.py` (+133 lines) · `services/homeai-presidio/` (new container) · `docker-compose.yml` · `scripts/u141-validate-presidio.py` + test corpus.

Every cloud-bound (Claude API) call via llm-router is routed through
homeai-presidio first. Redactor unreachable or errors = **503 to the
caller**, no soft pass-through. Telegram bot is exempt (talks to
anthropic SDK directly, not via llm-router). V174 logs every redaction
event with `trace_id`, `model_intent`, `redaction_counts`, `decision`.

## U143 — LiteLLM cost gateway + business priority
Files: V170, V172, V173, V175 · `services/homeai-litellm/` (new container) · monitoring metrics + alerts + Grafana dashboard.

ai_usage table gains `business_priority` (P0/P1/P2/P3), `capability_tag`,
`cost_gbp` columns (V170). V175 trigger auto-populates on INSERT. V172
backfills historical rows per the budget split (P0=30% floor, P1=35%,
P2=21%, P3=14%). V173 surfaces a `quota_status_7d` slug for the
dashboard. Prometheus alerts for `PresidioHardFail`, `PresidioSlow`,
`QuotaWouldBlock`, `TierCeilingBreached`, `P0FloorRunningLow`.

## U144 — Quota allocations
File: V171 (153 lines).

`quota_allocations` table: per-tier daily/monthly £ ceilings with
`enforce_mode` ('shadow' / 'hard') and shadow-mode block tracking.

## U145 — Per-realm Postgres role split (DRAFT)
File: V177 (DRAFT — do not apply without sign-off).

Adds `trading_role`, `personal_role`, `owner_role` Postgres roles that
map to the realm model so connection-pool partitioning becomes a real
defence layer rather than an app-layer GUC convention. **HIGHEST blast
radius migration in the stack** — pen-test on a copy before live apply.
Once consumers are migrated, `homeai_readonly` and `homeai_pipeline`
can be dropped.

## U135 follow-up
File: V159.

Retag dashboard slugs `realm='shared'` after `homeai-frontend/lib/db.ts`
turned on RLS enforcement (so `/app/*` pages, which connect as `work`,
can still read the slugs that need to be visible across realms).

---

## What remains unfinished

1. **V164c sweep** (~2h): widen CHECK constraints on the 349 declarative
   partition children that V164/V164b missed. Until done, INSERTs with
   `realm='personal'` into those partitions will fail.
2. **V165 narrow** (~30m once safe): drop 'family' from vocabulary
   after the 24h observation window. ✓ Already past observation window
   as of 2026-05-21; safe to apply once V164c is done.
3. **V177 pen-test + apply** (~half-day): assert RLS isolation under
   each new role, then migrate service connection strings.
4. **Pipeline downstream-missing bug** (recurring): Report Ingestion,
   Gmail Ingest, Invoice Pipeline, Nanny Pipeline all share a noOp-skip
   pattern that returns no item → master-router HttpRequest errors →
   stale-lease-recovery → dead_letter → flood → auto_pause. Patched in
   Report Ingestion 2026-05-21 (workflow now has `Complete Skipped
   Event` postgres node between `Already Processed?` true output and
   the noOp; also routes non-PDF MIME through same path). Same pattern
   needs applying to: Gmail Ingest's `Stop — Already Done`,
   Invoice Pipeline's equivalent, Nanny Pipeline's equivalent.
5. **DL threshold currently 200** (default was 5). Revert to 5 once the
   downstream-missing bug is fully fixed across all four pipelines.
