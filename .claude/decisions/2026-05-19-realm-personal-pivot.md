# ADR — Realm rename: FAMILY → PERSONAL; operational hardening is WORK-only

**Date:** 2026-05-19
**Status:** Proposed (awaiting sign-off before V164)
**Supersedes:** parts of `project_realm_split.md` (memory, locked 2026-05-14)
**Touches:** every realm-aware schema object, every slug, every service that calls `home_ai.set_realm()`.

---

## Context

The 2026-05-14 lock established a 3-realm model: OWNER / WORK / FAMILY. ARE
(entity 2 — Atlantic Road Estates Ltd) was placed in FAMILY by explicit
instruction, even though it is a separate Ltd, because the access pattern
("only Jo + family see this") aligned with Personal and Family data
already in entities 3 and 4.

Five days later the build priorities have moved on. The operational AI
investment (PII redaction, LiteLLM cost gateway, quota enforcement, cross-
entity RLS hardening) is being scoped exclusively for the **commercial
operations** — the pub, café, accommodation — i.e. entity 1, Atlantic
Road Trading Ltd. Spinning that infrastructure up for non-operational
data (Garmin metrics, family photos, household admin) costs engineering
time without proportional risk reduction: the threat model is different,
the volume is different, the regulatory pressure is different.

Two things follow:

1. The label "FAMILY" doesn't describe the contents any more. ARE +
   Personal + Family are united by *not being operational*, not by being
   family per se. **PERSONAL** is a more honest label for the bucket.
2. The realm split's job changes. Pre-pivot, the split was "who can see
   what". Post-pivot, the split is also "which realm gets the operational
   AI guardrails". WORK gets Presidio + LiteLLM + quota + role-split RLS.
   PERSONAL gets owner-only read access and no AI processing pipeline
   (existing read surfaces stay; nothing new is built for it).

---

## Decision

### Realm vocabulary (new)

| Realm | Identity (Google login) | Entities | Operational AI? |
|---|---|---|---|
| `owner` | `jolyon.sandercock@gmail.com` | all | yes (supersets WORK) |
| `work` | `info@malthousetintagel.com` + future pub-manager logins | 1 (Atlantic Road Trading Ltd) | yes — full hardening stack |
| `personal` | (no logins yet; OWNER-only in practice) | 2 (ARE), 3 (Personal), 4 (Family) | no — read-only, no new AI pipelines |

Lowercase token used everywhere in code, schema, slugs, and config.
Uppercase reserved for documentation prose ("the WORK realm").

`family` is removed from the realm vocabulary entirely. There is no
"family realm" any more — the bucket exists, but it's called `personal`
and contains all non-operational data, including ARE.

### What stays from the 2026-05-14 lock

- 5-layer defence in depth (Authelia / RLS-by-realm / RLS-by-entity /
  per-table CHECK constraints / app-level realm gates in lib/db.ts).
- Ingest-time realm tagging — mailbox-of-receipt drives the realm label.
- `home_ai.set_realm()` as the canonical entry point.
- OWNER as a superset that bypasses both realm and entity restrictions.

### What changes

- `home_ai.set_realm()` accepts `'personal'` and rejects `'family'`.
- Every CHECK constraint of the shape `realm IN ('owner','work','family','shared')` becomes `realm IN ('owner','work','personal','shared')`.
- Every RLS policy CASE branch on `app.current_realm = 'family'` becomes `= 'personal'`.
- Every existing row with `realm='family'` is updated to `realm='personal'` in the same migration.
- `vendor_invoice_inbox`, `audit_log`, `ai_usage`, and ~28 other realm-aware tables get a transactional rename pass.
- Slug `param_schema` notes that mention `family` are updated.
- Code-side: `lib/db.ts` DEFAULT_REQUEST_REALM stays `'work'`; references to `'family'` in any service get s/family/personal/.
- Memory updates: `project_realm_split.md`, `feedback_realm_must_be_designed_in.md`.

### What stays the same

- Layer 1 (Authelia auth) doesn't change today because there are no
  family logins yet; only Jo logs in, as OWNER. The realm switch matters
  for the eventual day when a pub-manager logs in: their cookie says
  `work`, they cannot read anything tagged `personal`.
- ARE data (Langholme rent, Principality mortgage statements, ARE bank
  feed) doesn't move; it just gets a new realm label.

---

## Scope of the migration (V164)

Affected tables (RLS-aware OR realm-tagged), by SELECT against `pg_policy` + `information_schema.check_constraints`:

| Group | Tables (representative) |
|---|---|
| Email pipeline | `email_received`, `vendor_invoice_inbox`, `vendor_invoice_lines`, `documents` |
| Finance | `bank_transactions`, `card_statements`, `card_statements_transactions`, `account_transfers`, `xero_bills`, `xero_bill_lines`, `mortgage_statements`, `properties` |
| HR | `tanda_staff`, `tanda_shifts`, `tanda_timesheets`, `holiday_requests` |
| Sales / ops | `touchoffice_department_sales`, `dojo_transactions`, `cashup_inputs`, `safe_movements`, `accommodation_bookings`, `restaurant_reservations` |
| Audit / telemetry | `audit_log`, `ai_usage`, `redaction_audit_log` (new in U141), `quota_allocations` (new in U144) |
| Config | `query_whitelist`, `bot_sender_whitelist`, `vendor_category_rules`, `vendor_site_rules` |

Exact list to be generated by `psql -c "SELECT polrelid::regclass FROM pg_policy WHERE pg_get_expr(polqual, polrelid) LIKE '%family%'"` plus a CHECK-constraint sweep at migration-time. The migration MUST be transactional (all-or-nothing) so no realm-aware policy is briefly broken.

---

## Penetration-test commitment

Before V164 merges:

```sql
-- assert: no policies still reference 'family'
SELECT polrelid::regclass, polname
  FROM pg_policy
 WHERE pg_get_expr(polqual, polrelid) ~ 'family'
    OR pg_get_expr(polwithcheck, polrelid) ~ 'family';
-- expected: 0 rows

-- assert: no CHECK constraints still allow 'family'
SELECT conrelid::regclass, conname
  FROM pg_constraint
 WHERE pg_get_constraintdef(oid) ~ '''family''';
-- expected: 0 rows (apart from historical migrations on disk)

-- assert: every previously-family row is now personal
SELECT realm, COUNT(*) FROM vendor_invoice_inbox GROUP BY 1;
-- expected: only owner/work/personal/shared
```

Run these on a `pg_dump`-restored copy before applying to live.

---

## Rollback

The migration is reversible via a sibling V164b that does the inverse
substitution. Keep it on disk but unapplied. If something goes wrong in
the soak window, apply V164b and reopen this decision.

---

## Risks called out

1. **Hidden references to the string `'family'`** in code. A repo-wide
   grep + manual review of each hit (some are legitimately about
   family-as-a-noun, e.g. `'family-fed'` in restaurant menus).
2. **Static seeds** (e.g. `seed-data.sql`) may insert rows with
   `realm='family'`. Re-running init from scratch must produce
   `realm='personal'`. Audit `postgres/seed-data.sql` and any one-shot
   bootstraps before merge.
3. **Memory drift.** `project_realm_split.md` and other memories
   reference FAMILY. They get re-written as part of V164's commit so
   future Claude sessions don't re-introduce the old vocabulary.
4. **Existing audit/telemetry rows** keep their original `realm` tag.
   The migration does an UPDATE on data, not a soft alias. Historical
   queries that filter `WHERE realm='family'` will return zero —
   intentional, but worth flagging if any dashboard hardcodes it.

---

## What this unblocks

- U145 (RLS role split) can name roles `trading_role` + `personal_role` + `owner_role` honestly. With `family_role` we'd be lying to ourselves about what the role does.
- Track-2 hardening sprints (Presidio, LiteLLM, quota) declare `realm='work'` and skip personal scopes cleanly. No "do we redact personal email too?" ambiguity.
- Future family logins (when/if they arrive) join under `personal`. No further rename needed.

---

## Sign-off

When you ACK this doc, V164 gets drafted as the transactional rename, V164b as the inverse, and U138-B starts in parallel (it doesn't touch realm semantics). Track 2 hardening sprints kick off after V164 is merged + soaked for 24h.
