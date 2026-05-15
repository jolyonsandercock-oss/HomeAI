# R1 — Realm Split, Label Phase

**Prereqs**: None. Pure additive. No enforcement yet.

**Realm**: cross-cutting (touches every table) — but the work itself is OWNER (migration + schema only).

**Remote vs in-person**: 100% remote.

**Why this sprint exists**: Jo locked the 3-realm access model on 2026-05-14 ([[realm-split-architecture]]). The R1 (label) phase adds a `realm` column to every table and populates it from entity_id / table-purpose without enforcing anything yet. This is the cheapest, lowest-risk first move: every later phase (R2 RLS, R3 Auth, R4 App, R5 Ingest, R6 Bot, R7 Backup) reads this column. Doing R1 cleanly now means R2 is a 30-minute policy flip, not a multi-day audit. **Skipping R1 means every later sprint pays the discovery cost.**

**Design rule (load-bearing)**: every track must end in a verifiable acceptance check that the realm value is correct for sample rows. No "should be" — only "is, verified by SELECT."

## Tracks

### T1 — V64 migration: add realm column to all tables (~45 min)

**Build**:
- New migration `V64__realm_column.sql`:
  ```sql
  -- For each table in public, add:
  ALTER TABLE <t> ADD COLUMN realm TEXT NOT NULL DEFAULT 'owner'
    CHECK (realm IN ('owner','work','family'));
  ```
- Populate via UPDATE per table according to T2 mapping (below) BEFORE the NOT NULL takes effect — order: ADD nullable, UPDATE, ALTER SET NOT NULL, ADD CHECK.
- Drop the DEFAULT after backfill so future inserts must declare realm explicitly.
- Index `realm` on every table > 10k rows (start with `emails`, `events*`, `vendor_invoice_inbox`, `caterbook_*`, `touchoffice_*`).

**Acceptance**:
- `SELECT COUNT(*) FROM information_schema.columns WHERE column_name='realm' AND table_schema='public'` matches `SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'`.
- `SELECT realm, COUNT(*) FROM <each-table> GROUP BY realm` returns no NULLs and only allowed values.

---

### T2 — Realm assignment rules (~30 min, lives inside V64)

**WORK** (`realm='work'`):
- `entity_id = 1` rows in all tables that have entity_id
- Tables that are inherently pub/cafe: `touchoffice_*`, `caterbook_*`, `workforce_*`, `epos_*`, `accommodation_*`, `staff*`, `till_reconciliation`, `manager_notes`, `guest_reviews`, `cafe_vendor_prompt_state`
- `vendor_invoice_inbox` rows where `site IN ('pub','cafe','shared')`
- `companies_house_*` rows for entity_id=1
- `bank_transactions` / `bank_accounts` rows that map to entity_id=1

**FAMILY** (`realm='family'`):
- `entity_id IN (2,3,4)` rows
- Inherently family-side tables: `properties`, `rent_payments`, `child_events`, `vehicles` (V62), child-health (when added), `companies_house_*` rows for entity_id=2 (AREL)
- `bank_transactions` / `bank_accounts` rows for entities 2/3/4
- `vendor_invoice_inbox` rows that arrived in jolyon@/personal mailboxes (need a new `source_mailbox` column — see T5)

**OWNER** (`realm='owner'` — superset, OWNER-only allowlist):
- `audit_log`, `security_audit_log`, `events*` (partitions included), `bot_instructions`, `bot_feedback`, `bot_sender_whitelist`, `dreaming_*`, `ai_usage`, `model_inventory_log`, `system_state`, `query_whitelist`, `query_rejections`, `static_context`, `companies_house_log` summary (not the per-entity alert rows)
- Justification: these are platform-internal / cross-realm and the OWNER is the only legitimate consumer.

**Acceptance**: a `v_realm_audit` view that lists per-table-per-realm row counts, hand-checked against the rules above for 5-10 spot tables.

---

### T3 — Mailbox-of-receipt provenance (~30 min)

The ingest layer (R5) will tag realm by mailbox. To make that possible later, R1 must guarantee every existing `emails` / `documents` / `vendor_invoice_inbox` row records which mailbox it came from. If the column is missing, add it now and backfill from existing metadata.

**Build**:
- `emails.source_mailbox` — confirm it exists; if not, add and backfill from `account` or `to_address`
- `documents.source_mailbox` — same
- `vendor_invoice_inbox.source_mailbox` — same; this is what lets us realm-tag an invoice at row creation in R5

**Acceptance**: every email/document/invoice row has a non-NULL `source_mailbox`.

---

### T4 — SPEC.md + AGENTS.md + sprint template updates (~30 min)

**Build**:
- Add **SPEC.md §2.x — Realm model** with the table from [[realm-split-architecture]] and the load-bearing invariant statement.
- Update **AGENTS.md** so Claude in future sessions reads the realm rule before designing.
- Update sprint-plan template (`/home_ai/.claude/templates/sprint.md` if exists, else `.claude/sprints/_template.md`) to require a `**Realm:**` line per track.
- Update **CLAUDE.md** (project root) with a one-line pointer to [[realm-split-architecture]].

**Acceptance**: grep finds `Realm:` in the sprint template; SPEC.md table-of-contents lists §2.x Realm model; AGENTS.md mentions realm in its first 50 lines.

---

### T5 — Migration-runner lint (~45 min)

A Postgres-level check that refuses to apply any migration that creates a `public.*` table without a `realm` column, unless the table is in the OWNER-only allowlist.

**Build**:
- New script `/home_ai/scripts/r1-migration-lint.sh` (or extend existing flyway pre-hook) that runs after each migration:
  ```sql
  SELECT t.table_name FROM information_schema.tables t
   WHERE t.table_schema='public' AND t.table_type='BASE TABLE'
     AND NOT EXISTS (
       SELECT 1 FROM information_schema.columns c
        WHERE c.table_schema=t.table_schema AND c.table_name=t.table_name
          AND c.column_name='realm'
     )
     AND t.table_name NOT IN ( <owner-only allowlist> );
  ```
- If any row returns, exit non-zero. Wire into the bootstrap / migration script so a future sprint plan that adds a table without realm fails loudly at apply-time.

**Acceptance**: deliberately drop the realm column from a throwaway test table → lint fails. Restore → lint passes.

---

### T6 — Verification on real queries (~20 min)

Before declaring R1 done, hand-run a handful of representative dashboard queries with `SET app.current_realm='work'` and `SET app.current_realm='family'` (note: no policies enforce these yet — this is a *dress rehearsal* for R2).

**Build**: a `/home_ai/scripts/r1-dress-rehearsal.sh` that:
- Sets realm=work, counts rows in 5 work tables (expect >0), 5 family tables (expect 0 if R2 were live)
- Sets realm=family, same
- Prints a summary table so we know what R2's policy switch will look like

**Acceptance**: the summary printout matches the intent. Any surprise rows (e.g. a `caterbook_*` row with realm=family) are caught and fixed before R2 starts.

## What this sprint does NOT do

- Does not enforce RLS (R2)
- Does not change Authelia / Caddy / build-dashboard (R3, R4)
- Does not change google-fetch ingest (R5)
- Does not realm-scope bot queries (R6)
- Does not change backups (R7)

Pure label + scaffolding. Safe to ship without a feature flag.

## Follow-on sprints (to be planned after R1 ships)

- **R2 — RLS enforcement**: app.current_realm GUC; convert entity_isolation policy. Shadow-DB test pass first. Risk: medium.
- **R3 — Auth**: finish Authelia forward_auth (blocked on tailscale-cert FQDN — see [[feedback_authelia_cookie_domain]]); identity→realm claim.
- **R4 — App**: build-dashboard reads realm from header; routes split `/work/`, `/family/`. Supersedes U47c basic-auth scaffold.
- **R5 — Ingest**: google-fetch tags realm at fetch by mailbox-of-receipt; immutable without OWNER override.
- **R6 — Bot/AI**: `query_whitelist.realm` column; bot-responder enforces caller's realm on every SQL.
- **R7 — Backup**: realm-scoped pg_dump path for selective restore.
