# Refactor plan — Anchor-first counterparty/entity resolver with abstention, contextual learned aliases, and lifecycle revalidation

> **Plan only.** No code, migrations, DB writes, Docker, or workflow activation in this turn. Concrete enough for another coding agent to execute safely later, in phases, behind a flag.

> **v2 (revised after external review).** Integrated 8 corrections: (1) no bare-`SET` standard for n8n — context set inside SQL functions / explicit `BEGIN…SET LOCAL…COMMIT`; (2) unique index made NULL-safe; (3) **explicit anchor-collision lifecycle** (§5.1a — the single most important change); (4) resolver treats caller-supplied `entity_id`/`realm` as **data, never authority**; (5) **mode enum** `disabled|shadow|review|enforce` replaces the binary flag; (6) **default-deny RLS** on new tables (no longer an open question); (7) **financial-identity layer** seeded from ledger sources is now a P0 blocker (§4a) — email-derived `counterparties` is not the attribution key; (8) backfilled anchors **classified by role** (identity/routing/category).

---

## 1. Verdict on the existing design

**Sound-with-changes.** `docs/anchor-resolver-abstention-design-review.md` gets the contract right (exact/strong anchors → abstain rather than nearest-neighbour; "right two rows or nothing"; volatility tiering; refusal as a first-class outcome). Five corrections are required before it fits this system:

1. **Input is an evidence object, not `resolve(raw_string)`.** Bank/invoice records carry far more discriminating signal than the name string (account numbers, account codes, domains, references). Resolving on the string alone throws away the strongest anchors.
2. **Anchors are scoped, not globally unique.** `TOM106`/`MAL125`, sort codes, references and even domains are unique only within a `(source_system, source_account)` or `(entity, realm)` scope. A global unique assumption will mis-resolve.
3. **Learned aliases must be contextual + revalidated.** The design's append-only "learned alias = raw text → id" becomes a silent long-term error source the moment the registry changes. Aliases must carry their evidence + a registry fingerprint and be re-checked on a schedule.
4. **Postgres-native, not SQLite.** The system is PostgreSQL 16 with `pg_trgm` already in use (V168, V228). Use `tsvector`/GIN + `pg_trgm` (and optionally `fuzzystrmatch` for phonetic) — do **not** introduce SQLite.
5. **It must wrap, not replace, the existing resolvers.** `vendor_category_rules` + `resolve_invoice_site()` already *are* a lexical anchor resolver for invoices; the refactor formalises them into a scoped-anchor store and adds the abstention gate + learned-alias lifecycle, rather than greenfielding.

---

## 2. Refactor objective

Improve counterparty/entity resolution **accuracy** and **memory over time** by making resolution:
- **anchor-first** — prefer deterministic, contextual anchors (IDs/codes/domains) over name similarity;
- **abstaining** — auto-assign only when deterministic evidence clears a calibrated gate; otherwise refuse and route to human review (a wrong auto-resolve corrupts the ledger and is strictly worse than a wrong abstain);
- **self-improving but self-correcting** — human confirmations become contextual learned aliases that are continuously revalidated so old confirmations don't silently rot;
- **enrichment-only** — assigns internal attribution (counterparty / entity / site / category); never writes back to or overrides Xero / Dext / Bank / ICRTouch / Caterbook (SPEC §1.1: "the system DB is a mirror and enrichment layer only").

---

## 3. Current-state summary (with file references)

**Entity graph (the registry).** `counterparties` — `postgres/migrations/V228__u242_counterparty_registry.sql`. Built deterministically from `emails` by `home_ai.build_counterparty_registry()` (org=domain, person=primary_email; identity unique-indexes on those). Fuzzy-linked to `vendor_invoice_inbox.vendor_name` via `pg_trgm` (`linked_vendor`,`linked_confidence`). RLS: open base SELECT + restrictive realm (array `&&`). **Email-sender-derived — not currently the attribution key for bank/invoice records.**

**Invoice vendor resolution (de-facto anchor resolver).** `vendor_category_rules` — V33 (`domain_pattern` POSIX regex → `category`,`vendor_display`,`priority`), V59 (`site` shared/cafe/pub/inn; UNIQUE`(domain_pattern,site)`), V63/V63a (`subject_pattern` anchor, e.g. `MAL125`; `resolve_invoice_site()` rule-first then heuristic `CASE`, opt-in subject in V63a). Evidence fields on `vendor_invoice_inbox`: `vendor_domain`, `vendor_name`, `vendor_id`, `account`, `subject`, `entity_id`, `realm`, `category_canonical`, `site`, `amount_seen`/`gross_amount`, `canonical_id`, `xero_bill_id`, `paperless_doc_id`, `source_email_id`. **No abstention** — falls through to `'shared'`/`'Other'`.

**Line-level learned feedback (pattern to mirror).** `line_category_feedback` — V168. Human corrections keyed by `(line_id, vendor_domain, description_raw)`, `source` enum (`manual|nightly_haiku|rule_match|xero_sync`), `confidence`, `corrected_by`, `realm`, GIN `pg_trgm` on `description_lower`. **Line-category, not counterparty; no revalidation.**

**Bank resolution (the biggest gap).** `bank_transactions` — V71/V71b. Columns: `description` (raw narrative), `reference`, `bank_account_id`, `entity_id`, `amount`, `transaction_date`, `category`,`category_confidence`,`category_source`, `xero_transaction_id`, `reconciled`, `realm`. **No `counterparty_id`** and no counterparty resolver — narrative→entity attribution is effectively manual / category-only. Property attribution exists narrowly via `account_property_map` (see British-Gas-attribution memory).

**Extensions:** `pg_trgm` installed; `fuzzystrmatch`/`unaccent` **not** (phonetic/accent-fold would need enabling).

**Invariants in force (AGENTS.md / SPEC §1.2, §2.2, §2.3):** AI is enrichment only (never routes/writes); pipelines deterministic+idempotent; `SET LOCAL app.current_entity` before every write; realm+entity set in the same txn as dependent reads/writes; HMAC-sign event payloads before `INSERT INTO events`; idempotency-check before processing/insert; secrets in Vault only. Note the **systemic permissive-null RLS branch** (`current_setting('app.current_realm',true) IS NULL → true`) present in V228/V168 etc., tracked for default-deny under U249 — new policies should follow whatever U249 settles on.

---

## 4. Proposed architecture

A single deterministic resolver, `home_ai.resolve_counterparty(evidence jsonb) → jsonb`, sitting **between ingestion and attribution write**, with four candidate-generation stages feeding one abstention gate, backed by three tiers:

```
evidence object ─► resolve_counterparty()
   stage 1  exact strong anchor (counterparty_anchor, scoped + unique-in-scope)   ── HIGH
   stage 2  contextual learned alias (counterparty_resolution_log, validation=valid) ── HIGH
   stage 3  lexical/trigram candidates (counterparties + vendor_category_rules + pg_trgm) ── scored
   stage 4  abstention gate (HIGH | ABSTAIN)
              HIGH    → return {counterparty_id, entity_id, realm, site?, confidence, anchors[]}
                        caller writes attribution + promotes a learned alias
              ABSTAIN → return {abstain, reason, top_candidates[]}; caller writes a review-queue item
```

Tiers (Sibyl volatility model, mapped to this system):
- **Durable entity graph** — `counterparties` (V228) + new `counterparty_anchor` (scoped anchors) + `counterparty_alias` (curated name aliases).
- **Append-only event/learning log** — `counterparty_resolution_log` (contextual confirmed mappings + evidence + fingerprint + validation lifecycle) and the existing `events` table (audit of resolutions/abstentions).
- **Live** — the current ingest batch's working set (in-memory in the calling pipeline).

The resolver is **pure enrichment**: it never inserts/updates source-of-truth rows; it returns a decision the pipeline records as attribution metadata + an `events` audit row.

### 4a. Financial-identity layer (review #7 — P0 blocker, resolves former Q1)

`counterparties` (V228) is **email-sender-derived** (org=domain, person=address) with only a fuzzy `pg_trgm` link to vendor names. It was never designed to be the ledger identity, and bank payees / Xero contacts / Dext suppliers frequently have **no email at all**. Building financial attribution on it would inherit a graph shaped for cultural-memory dossiers, not the ledger.

So the resolution target is a **financial identity**, seeded from ledger sources, with the email graph linked *to* it (not the other way round):
- New table **`financial_counterparty`** — the canonical attribution key: `id`, `display_name`, `kind` (`supplier`,`customer`,`bank_payee`,`internal`,`hmrc`,`other`), `xero_contact_id` null, `dext_supplier_id` null, `vat_number` null, `default_entity_id`/`default_realm`, `status` (`active`,`merged`,`disabled`), timestamps.
- Seed from (in trust order): **Xero contacts** (authoritative), **Dext suppliers**, **bank payees** (distinct cleaned narratives already reconciled to a Xero txn), and **`vendor_category_rules`** identity rows. Email `counterparties` link via a nullable `financial_counterparty_id` FK on `counterparties` (curated/confirmed link, not the fuzzy `linked_vendor`).
- `counterparty_anchor.counterparty_id` and `counterparty_resolution_log.counterparty_id` reference **`financial_counterparty(id)`**, not `counterparties(id)`.
- Source-of-truth respected: Xero/Dext IDs are stored for linkage and **read-only** — the resolver never writes back to Xero/Dext; it only records which financial identity a record maps to.

This is the one change that must land in **P0/P1** before anchors mean anything, because the anchor/alias targets must point at the ledger identity, not the email graph.

---

## 5. Data model changes (proposed; not written)

> Migration numbers TBD at execution (claim the next free `V###` per the "check sprint/migration number first" rule — V250 is the latest planned at time of writing). Each table: `ENABLE ROW LEVEL SECURITY` with **default-deny realm/entity policies** (review #6 — no permissive-null branch; an unset realm/entity returns **no rows**, not all rows), `GRANT SELECT` → `homeai_readonly`, `GRANT SELECT,INSERT,UPDATE` → `homeai_pipeline`. All writers set context in-txn (§6.4/§6.5: `SET LOCAL` inside a function/transaction, never bare `SET`).

**5.1 `counterparty_anchor`** — scoped anchors (generalises `vendor_category_rules` domain/subject anchors + adds bank/ID anchors).
- `id bigserial pk`
- `anchor_type text` CHECK in (`email_domain`,`invoice_account_code`,`bank_account_id`,`bank_reference`,`sort_code`,`iban`,`vendor_domain_regex`,`subject_token`,`vat_number`)
- **`anchor_role text` CHECK in (`identity`,`routing`,`category`)** — *(review #8)* only `identity` anchors are counterparty-resolution evidence; `routing` feeds site, `category` feeds category. A `vendor_category_rules` row that only assigns a category must NOT become identity evidence.
- `anchor_value_normalized text` (lowercased/trimmed/de-formatted; for regex types store the pattern)
- `scope_type text` CHECK in (`global`,`source_system`,`source_account`,`entity`,`realm`) — anchors are unique only within scope
- **`scope_value text NOT NULL DEFAULT ''`** *(review #2)* — empty string for `global`, never NULL, so the unique index actually dedupes global rows
- `counterparty_id bigint references counterparties(id)` (target is the **financial identity**, §4a, not the email counterparty)
- `entity_id int`, `realm text`
- `source_system text` (`bank`,`dext`,`xero`,`email`,`icrtouch`,`caterbook`,`manual`)
- `confidence_class text` CHECK in (`strong`,`medium`,`weak`)  — `strong`=ID/code, `weak`=name-ish
- `first_seen_at`, `last_seen_at timestamptz`, `status text` CHECK in (`active`,`collided`,`disabled`) DEFAULT `active`, `collided_at`, `collided_with bigint[]`
- Indexes: **`UNIQUE NULLS NOT DISTINCT (anchor_type, anchor_value_normalized, scope_type, scope_value, anchor_role) WHERE status='active'`** *(review #2 — `NULLS NOT DISTINCT`, PG16; combined with the non-null `scope_value` default this guarantees one active anchor per (type,value,scope,role))*; btree `(counterparty_id)`; GIN `pg_trgm` on `anchor_value_normalized` for weak/name anchors.
- A `strong identity` anchor may not be `scope_type='global'` unless explicitly whitelisted (forces scoping of IDs that look unique but aren't, e.g. bank references).

**5.1a Anchor-collision lifecycle (review #3 — the single most important change).**
Uniqueness alone is not enough: if a second mapping for the same `(type,value,scope,role)` simply *fails to insert*, the system never learns the anchor is ambiguous. So collisions are represented explicitly, never silently rejected:
- Anchor writes go through `home_ai.upsert_anchor(...)` (not raw INSERT). On a would-be unique violation it does **not** raise — it transitions **all** competing mappings (the existing active row + the new one) to `status='collided'`, records `collided_with`/`collided_at`, and emits a `counterparty.anchor.collision` audit event + a review-queue item.
- The resolver treats `collided` anchors as **never HIGH** (they're disqualifying evidence, not silent). A collided anchor that previously auto-resolved stops doing so immediately.
- Resolution: human review can (a) split the scope (e.g. make the anchor `source_account`-scoped so it's unique again), (b) `disable` one mapping, or (c) create a more specific anchor. Re-activation is explicit and audited.
- State machine: `active → collided` (on conflict) → `active` (after a scope-split that restores in-scope uniqueness) | `disabled` (human). Never auto-`active` from `collided`.

**5.2 `counterparty_resolution_log`** — contextual learned aliases + lifecycle.
- `id bigserial pk`
- `source_system text`, `source_account text`
- `raw_counterparty_normalized text`
- `anchor_fingerprint text` — stable hash of the *set of anchors present at confirmation* (sorted `anchor_type:value`), so we can detect when the evidence shape changes
- `counterparty_id bigint references counterparties(id)`
- `entity_id int`, `realm text`, `site text` null, `category text` null, `property_id` null
- `confirmed_by text`, `confirmed_at timestamptz`
- `validated_at timestamptz`, `validated_by text` (job or human)
- `validation_status text` CHECK in (`valid`,`stale`,`collided`,`target_changed`,`needs_re_review`,`disabled`) default `valid`
- `evidence_json jsonb` — the full evidence object at confirmation time (for audit + revalidation replay)
- `registry_fingerprint text` — hash of the target counterparty's identity columns at confirmation (domain/primary_email/realms/parent), so a merge/rename trips revalidation
- Indexes: **`UNIQUE (source_system, source_account, raw_counterparty_normalized, anchor_fingerprint) WHERE validation_status='valid'`** (prevents duplicate *active* aliases for the same context+evidence; allows superseded history to remain); btree `(counterparty_id)`, `(validation_status)`, `(validated_at)`.
- Note: keying on `anchor_fingerprint` (not raw text alone) is the fix for "unsafe alias" — a raw string confirmed under one evidence shape does not auto-apply under a different shape.

**5.3 `counterparty_resolution_review_queue`** — abstention items.
- `id bigserial pk`, `created_at`, `status text` (`open`,`resolved`,`ignored`,`auto_closed`)
- `source_system`, `source_ref` (document_id / bank txn id / invoice id), `entity_id`, `realm`
- `evidence_json jsonb`, `abstain_reason text`, `top_candidates jsonb` (ranked `[{counterparty_id, score, why}]`)
- `suggested_action text` (`confirm_existing`,`create_new`,`mark_non_financial`,`split_merge`)
- `resolved_by`, `resolved_at`, `resolution_counterparty_id`, `decision text`, `reversed_of bigint null` (reversibility)
- Indexes: `(status, created_at)`, `(source_system, source_ref)`, unique partial to dedupe open items per `(source_system, source_ref)`.

**5.4 `counterparty_registry_version` + `counterparty_merge_history`** — lifecycle backbone.
- `counterparty_registry_version (counterparty_id, version int, identity_fingerprint text, changed_at, change_kind text)` — bump on rename/merge/split/disable; revalidation compares `resolution_log.registry_fingerprint` to current.
- `counterparty_merge_history (from_id, into_id, merged_at, merged_by, reason)` — so a resolution pointing at a merged-away id can be auto-redirected or flagged.

**5.5 Extend, don't replace.** Add `counterparty_id bigint references counterparties(id)` + `counterparty_confidence real` + `counterparty_source text` to `bank_transactions` and `vendor_invoice_inbox` (mirrors the existing `category`/`category_confidence`/`category_source` triplet on `bank_transactions`). `vendor_category_rules` stays as-is and is **backfilled into `counterparty_anchor`** as `vendor_domain_regex`/`subject_token` strong anchors (single source of truth going forward; rules table kept read-compatible during transition).

---

## 6. Resolver algorithm

`home_ai.resolve_counterparty(evidence jsonb) RETURNS jsonb` — `SECURITY DEFINER`, sets realm+entity from the evidence inside its own txn, deterministic, **no LLM**.

**6.1 Evidence object** (superset; each pipeline fills what it has):
```text
{ source_system, source_account, entity_hint, realm,
  raw_counterparty, invoice_account_code, email_domain,
  bank_reference, sort_code, account_number, vat_number,
  amount, date, document_id/source_ref }
```
Availability by source:
- **bank** (`bank_transactions`): source_system=bank, source_account=`bank_account_id`, raw_counterparty=`description`, bank_reference=`reference`, amount, date, entity_hint=`entity_id`, realm. (sort_code/account_number only if parseable from narrative.)
- **invoice** (`vendor_invoice_inbox`, Dext/email): email_domain=`vendor_domain`, invoice_account_code=`account` (e.g. MAL125), raw_counterparty=`vendor_name`, subject token, amount=`gross_amount`, date=`invoice_date`, document_id=`paperless_doc_id`/`source_email_id`, entity_hint, realm.
- **Dext/Xero**: vendor id / Xero contact id (treat as `strong` anchors once mapped), account code, amount, date. **Read-only — never written back.**
- **email**: email_domain, from-address, subject token, realm.

**6.2 Stages**
1. **Strong-anchor pass.** Normalise + extract anchors (domain, account code, account id, reference, sort code, vat). For each strong anchor, look up `counterparty_anchor` **within its scope** (`source_account`→`entity`→`realm`→`global`, most-specific first). If exactly one `active` anchor matches in the most specific scope that has any match → candidate `confidence=HIGH`. If the unique-in-scope index shows a collision (multiple), do **not** pick — mark `anchor_collision`.
2. **Contextual learned alias.** Look up `counterparty_resolution_log` by `(source_system, source_account, raw_counterparty_normalized, anchor_fingerprint)` with `validation_status='valid'`. Hit → `HIGH`. If a matching row is `stale`/`needs_re_review`/`collided`/`target_changed` → do **not** use it; treat as ABSTAIN-eligible (`stale_alias`).
3. **Lexical / trigram candidates.** Over `counterparties.display_name` + `counterparty_alias` + `vendor_category_rules` (+ optional `tsvector` index): rank candidate tokens by **document-frequency (rarest first)**; require the discriminating token's DF ≤ `k`; compute `coverage` (share of raw_counterparty matched) and `margin` (top1−top2 score). Trigram (`similarity`) only contributes a candidate, never an auto-resolve on its own.
4. **Gate** (§7).

**6.3 Output**
```text
HIGH    → { decision:'resolve', counterparty_id, entity_id, realm, site?, category?,
            confidence, stage, anchors:[...], registry_fingerprint }
ABSTAIN → { decision:'abstain', reason, top_candidates:[{counterparty_id,score,why}], evidence_echo }
```
The function returns a decision; the **caller** performs writes (attribution + `events` audit + learned-alias promotion + review-queue insert), each with `SET LOCAL app.current_entity`, HMAC-signed events, idempotency-checked.

**6.4 Trusted context — evidence is data, never authority (review #4).**
The evidence object is caller-supplied JSON, so it must not be used to set or widen security context. Rules:
- The **caller** opens the transaction and sets the *trusted* context from the **source row it already has RLS access to** — `SET LOCAL app.current_entity = <source_row.entity_id>` and `home_ai.set_realm(<source_row.realm>)` — **not** from `evidence.entity_id`/`evidence.realm`.
- The resolver reads context via `current_setting('app.current_entity')` and uses `evidence.entity_id`/`evidence.realm` only as **scoring/scope hints for candidate generation** — it can never use them to read across an entity/realm it isn't already in. If `evidence.entity_id` disagrees with the trusted context, that's a flagged condition (`cross_entity_ambiguity` → ABSTAIN), not a widen.
- The resolver function is defined with a **fixed `search_path` (`pg_catalog, public`)** and minimal privileges. Prefer `SECURITY INVOKER` so it runs as the caller's role under the caller's RLS; if `SECURITY DEFINER` is needed for a specific grant, it still must not re-set entity/realm from evidence.

**6.5 n8n write pattern (review #1 — supersedes the v1 "use bare SET" note).**
Bare `SET app.current_entity` leaks context across n8n's pooled connections — do **not** standardise it. Two acceptable patterns, in order of preference:
1. **Context handled inside a SQL function.** n8n calls `SELECT home_ai.resolve_and_attribute(<source_ref>, <evidence>)`; the function sets `SET LOCAL` internally (valid — a function body runs inside the statement's transaction, so the LOCAL setting is scoped to that call and cleared after, no leak). This is the recommended path and sidesteps the node entirely.
2. **Explicit transaction in one query:** `BEGIN; SET LOCAL app.current_entity=$1; SELECT home_ai.set_realm($2); <write>; COMMIT;` — the wrapping `BEGIN…COMMIT` makes `SET LOCAL` valid and pool-safe. (The 2026-06-08 gmail-ingest breakage was an *unwrapped* multi-statement `SET LOCAL …; INSERT …`; inside an explicit transaction block it is fine — verify against the n8n Postgres node before relying on it.)
Service-side (Python) writers continue to use `SET LOCAL` in their own transactions.

---

## 7. Abstention gate (concrete)

```
HIGH (auto-resolve) iff ANY:
  - a strong anchor matched UNIQUELY in its most-specific scope (stage 1), OR
  - a contextual learned alias matched and validation_status='valid' (stage 2), OR
  - lexical: discriminating-token DF ≤ k  AND  coverage ≥ C  AND  margin ≥ M
            AND no competing candidate within margin from a different entity/realm

ABSTAIN otherwise, with an explicit reason:
  anchor_collision | no_anchor | low_margin | rare_token_low_coverage
  | fuzzy_only | stale_alias | target_changed | cross_entity_ambiguity
```
Defaults (to be calibrated, §10, not guessed into production): `k` = DF that selects ~1 entity (start: token present in ≤1 registry row), `C` = 0.6, `M` = 0.25 normalised. **Asymmetric:** a candidate that would auto-resolve *across* `entity`/`realm` boundaries requires a strong/contextual anchor — lexical alone never crosses entities (prevents the ledger-corruption class). Wrong-resolve is weighted far above wrong-abstain in calibration.

---

## 8. Revalidation loop

Scheduled job (n8n workflow `revalidate-resolution-log-v1` **or** a host-cron'd `SELECT home_ai.revalidate_resolution_log()`; align with the existing supervisor/cron pattern). Daily. For each `resolution_log` row with `validation_status='valid'`:

1. **Replay** `evidence_json` through `resolve_counterparty()` (in a read-only/shadow mode that does not write).
2. Set status:
   - resolver still returns the same `counterparty_id` at HIGH → touch `validated_at`, stay `valid`.
   - resolver now ABSTAINs `anchor_collision`, or the once-rare token is no longer discriminating → `collided`.
   - `registry_fingerprint` ≠ current target fingerprint (rename/merge/split) or target in `counterparty_merge_history` / disabled → `target_changed`.
   - `(source_account)` scope no longer exists / changed → `needs_re_review`.
   - resolver returns a *different* counterparty at HIGH → `needs_re_review` (never silently re-point).
3. Any non-`valid` transition: insert a `counterparty_resolution_review_queue` item + emit an `events` audit row (`counterparty.alias.revalidation`), HMAC-signed, idempotent. **Never auto-resolve on a non-valid alias** thereafter.
4. Circuit-breaker + rate-limit (mirror `u241-supervisor`): cap review-queue emissions/run so a registry rebuild doesn't flood.

Each alias therefore always carries `validated_at`, `validated_by(_job)`, original `evidence_json`, `registry_fingerprint`, and a live `validation_status`.

---

## 9. Review queue workflow (human UX)

Surface in the existing dashboard review surface (build-dashboard) + Telegram for at-the-pub triage (mirror `cafe_vendor_prompt_state`, V59).

Each open item shows: **raw evidence**, **top candidates with scores + why**, **abstain reason**, **suggested action**. Reviewer can:
- **confirm existing** counterparty → writes `counterparty_resolution_log` (contextual, with evidence + fingerprint) + optionally promotes a scoped `counterparty_anchor` + audit event; updates the source record's `counterparty_id`/`counterparty_source='human'`.
- **create new** counterparty (insert into `counterparties`, then confirm).
- **mark non-financial / ignore** → closes item, optionally seeds a negative anchor.
- **split / merge** → writes `counterparty_merge_history`, bumps `counterparty_registry_version`, triggers revalidation of affected aliases.
- **all decisions reversible** (`reversed_of`, append-only; never hard-delete a confirmed mapping — supersede it).

Confirmations are the system's learning signal; abstentions that pile up unactioned are themselves a metric (§10) so rubber-stamping pressure is visible.

---

## 10. Metrics and calibration

**Calibrate from labelled history, not intuition.** Label set = existing `line_category_feedback` corrections + `bank_transactions`/`vendor_invoice_inbox` rows already tied to a Xero contact/bill (high-trust labels) + accumulated review-queue confirmations. Hold out a test slice. Sweep `(k, C, M)` to **minimise wrong-resolve subject to an acceptable abstain rate**, optimising the asymmetric loss (wrong-resolve ≫ wrong-abstain).

Scorecard (per source_system + overall): correct-resolve, **correct-abstain**, wrong-resolve, wrong-abstain, review volume, review turnaround, learned-alias **reuse rate**, **revalidation failure rate** (aliases going non-valid/period), and a **risk-weighted wrong-resolve** (by `amount` band / cross-entity flag).

**Verification harness** (project style — SQL assertions that `RAISE EXCEPTION`; psql non-zero on fail; mirror `scripts/verify-counterparty-registry.sql`): `scripts/verify-counterparty-resolver.sql` asserting e.g. golden evidence rows resolve to the expected id at HIGH; known-ambiguous rows ABSTAIN; a fabricated counterparty string ABSTAINs (never nearest-neighbour); a collided anchor ABSTAINs; a `target_changed` alias is not used.

---

## 11. Migration / backfill plan

- **M1 (additive tables):** `counterparty_anchor`, `counterparty_resolution_log`, `counterparty_resolution_review_queue`, `counterparty_registry_version`, `counterparty_merge_history` — all with RLS/grants. Idempotent (`CREATE … IF NOT EXISTS`).
- **M2 (extend source tables):** add nullable `counterparty_id`/`_confidence`/`_source` to `bank_transactions`, `vendor_invoice_inbox`. Nullable + default null = no rewrite of source-of-truth semantics.
- **M3 (seed anchors — classified by role, review #8):** backfill `counterparty_anchor` from `vendor_category_rules`, but **classify each rule** before inserting: a rule that maps a vendor domain to a *specific counterparty* → `anchor_role='identity'`; a rule that only assigns `site` (e.g. cafe/pub routing) → `routing`; a rule that only assigns `category` → `category`. **Only `identity` anchors become counterparty-resolution evidence.** Also seed `email_domain` identity anchors from `counterparties`→`financial_counterparty` *confirmed* links (not the fuzzy `linked_vendor`), and property anchors from `account_property_map` (`routing`). Rules that are ambiguous on classification seed as `category`/`routing` (the safe, non-identity default), surfaced for review — never silently promoted to identity.
- **M4 (seed aliases, conservatively):** backfill `counterparty_resolution_log` **only** from high-trust existing labels (rows already linked to a Xero contact/bill), each with a synthesised `evidence_json` + `registry_fingerprint`, `validation_status='needs_re_review'` so the first revalidation pass blesses them rather than trusting them blind.
- **Resolver + revalidation functions:** `CREATE OR REPLACE` PL/pgSQL (idempotent).
- Each migration: applied via the standard `docker exec … psql -v ON_ERROR_STOP=1`; followed by its verification script; committed with the verify script (per the P1-plan convention).
- **No backfill writes attribution automatically.** Backfill seeds anchors/aliases; attribution on existing rows happens later in shadow mode (Phase 2) gated by the gate.

---

## 12. Test / verification plan

- `scripts/verify-counterparty-resolver.sql` — golden-resolve, must-abstain, fake→abstain, collision→abstain, stale-alias→abstain, cross-entity→abstain (RAISE EXCEPTION on fail).
- `scripts/verify-resolution-revalidation.sql` — seed a merge/rename, run `revalidate_resolution_log()` in shadow, assert affected aliases flip to `target_changed`/`collided` and a review item is emitted.
- RLS assertions — as a non-owner realm role, confirm anchors/aliases for other realms are invisible (catch the entity/realm-leakage risk).
- Shadow-mode replay over a recent window (e.g. 90 days of `bank_transactions` + invoices): produce the §10 scorecard **without writing attribution**; gate go-live on wrong-resolve below target.
- Idempotency: re-running resolve + promote on the same `source_ref` produces no duplicate aliases/events (unique partial indexes + idempotency keys).

---

## 13. Rollback plan

- **Mode switch** `resolver.mode` (in `static_context`, settable per `source_system`) *(review #5 — replaces the binary flag, which would have flooded review)*:
  - `disabled` — resolver not invoked; no writes, no queue.
  - `shadow` — resolver scores and writes **metrics only** (no attribution, no queue items). The default for P1 and for replay/calibration; produces the §10 scorecard without operational noise.
  - `review` — abstentions create review-queue items; HIGH still does **not** auto-write attribution (used to build the human-confirmation/learned-alias corpus before trusting the gate).
  - `enforce` — HIGH auto-resolves (writes attribution + promotes alias); ABSTAIN queues.
  - Rollback = drop a `source_system` back to `shadow`/`disabled` instantly. P1 ships `shadow`, P2 `review`, P5 flips to `enforce` per pipeline.
- Tables are additive; new columns nullable → drop/ignore to revert with no source-of-truth impact.
- Functions are `CREATE OR REPLACE` → revert by re-applying the prior definition.
- Learned aliases are append-only + superseded (never hard-deleted) → a bad confirmation is reversed, not lost.
- n8n revalidation workflow: deactivate to stop the loop; its writes are review items + audit events only (no source mutation).

---

## 14. Open questions / decisions needed

**Decided by review (no longer open):**
- ~~Q1 financial identity~~ → **DECIDED:** seed a `financial_counterparty` layer from Xero/Dext/bank/vendor-rules; link email `counterparties` to it (§4a). P0 blocker.
- ~~Q6 RLS~~ → **DECIDED:** **default-deny** on all new tables from day one (no legacy consumers); do not copy the permissive-null branch.

**Still open:**
1. **Phonetic fallback** — enable `fuzzystrmatch`/`unaccent` for OCR'd/garbled short names, or stay `pg_trgm`-only? (Design-review §7 argues trigram/phonetic over vectors here.) `fuzzystrmatch` is not currently installed.
2. **Where does auto-resolve write?** Enrichment columns only (proposed), or also surface a Xero-contact *suggestion* (never auto-pushed — Dext/Xero are source-of-truth)?
3. **Revalidation cadence** — daily full vs. event-driven (only aliases whose target changed; the `counterparty_registry_version` bump is the hook).
4. **Gate-threshold home** — store `(k,C,M)` in `static_context` (tunable without deploy, recommended) vs. baked into the function.
5. **Merge auto-redirect** — when a target is merged, auto-redirect aliases to `into_id` or force re-review? (Recommend re-review for financial safety.)

## 15. Phased implementation checklist

- [ ] **P0 — financial identity + sign-off (blocker):** build `financial_counterparty` (§4a) and seed it from Xero/Dext/bank/vendor-rules; add the `counterparties.financial_counterparty_id` link. Settle remaining open items §14.1–5 (esp. threshold home). Claim migration numbers. *Nothing downstream is meaningful until the attribution key exists.*
- [ ] **P1 — anchors + resolver in `shadow` mode:** M1+M2+M3 migrations (default-deny RLS); `home_ai.upsert_anchor()` with the collision lifecycle (§5.1a); `resolve_counterparty()` + gate + trusted-context handling (§6.4); `verify-counterparty-resolver.sql`. `resolver.mode='shadow'` → scores + metrics only, **no attribution, no queue**.
- [ ] **P2 — review queue + learned aliases:** `review_queue` UX (dashboard + Telegram); confirm/create/ignore/merge actions writing contextual `resolution_log` + audit events; M4 conservative alias seed (`needs_re_review`).
- [ ] **P3 — calibration:** build label set; shadow-replay scorecard; sweep `(k,C,M)`; set thresholds; gate go-live on wrong-resolve target.
- [ ] **P4 — revalidation loop:** `revalidate_resolution_log()` + scheduled workflow + `verify-resolution-revalidation.sql`; merge/version backbone (`registry_version`, `merge_history`).
- [ ] **P5 — enable auto-resolve per pipeline, one at a time:** flip the flag scoped per source_system; start with invoices (richest anchors), then bank, watching the scorecard + review volume; each integration declares its action (auto-resolve | queue | emit event | request confirmation | promote alias).
- [ ] **P6 — agent memory layer (separate, §16):** anchor-first recall + abstention on `MEMORY.md`.

---

## 16. Agent memory layer (kept modest)

Financial records contain anchors; conversational memory often does not, so apply the *contract* not the *machinery*:
- **exact keyword/anchor recall first** over the memory index; return the 1–2 matching fact files, not the whole index.
- **abstain with "no memory found"** when no discriminating keyword matches — do not surface a loosely-related fact the model then over-trusts.
- **semantic fallback only for exploratory recall**, explicitly flagged as non-authoritative; never for facts an action depends on.
- memory entries carry **stable IDs, `aliases`, `validated_at`, and `superseded_by`/`deprecated`** so a renamed/retired fact can't silently resurface (mirrors `resolution_log` lifecycle).
- **Premature today** at ~50 facts — implement when the memory grows to hundreds and recall precision starts to matter; track as a deferred item, not P1.

---

## 17. Integration points (summary table)

| Integration | Action when HIGH | Action when ABSTAIN |
|---|---|---|
| Bank ingestion / reconciliation (`bank_transactions`) | set `counterparty_id`/`_confidence`/`_source='resolver'`, emit `counterparty.resolved` event | review-queue item + `counterparty.abstained` event; leave `counterparty_id` null |
| Invoice / vendor categorisation (`vendor_invoice_inbox`, `resolve_invoice_site`) | set counterparty + keep `vendor_category_rules` site/category; promote anchor | review-queue item; fall back to current heuristic site but flag low-confidence |
| `vendor_invoice_lines` | inherit invoice counterparty | n/a (line-level stays on `line_category_feedback`) |
| Counterparty dossiers (V228/U242) | use resolved id as the dossier key | exclude unresolved from dossiers |
| Dashboard review queue | n/a | render item; capture decision → learned alias |
| n8n exports | call `home_ai.resolve_and_attribute(...)` (a SQL function that sets context internally, §6.5) from pipeline write nodes — no bare `SET` | same function path writes the review item |

> n8n note (revised, review #1): write nodes call the resolver/attribution **SQL function** which sets context internally (`SET LOCAL` inside the function body — pool-safe), OR wrap writes in an explicit `BEGIN; SET LOCAL …; …; COMMIT;` single query. Do **not** standardise bare `SET app.current_entity` (it leaks across pooled connections). See §6.5. Service-side (Python) writers use `SET LOCAL` in their own transactions.
