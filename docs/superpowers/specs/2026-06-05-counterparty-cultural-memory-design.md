# Counterparty Cultural Memory — Design Spec

**Date:** 2026-06-05 · **Sprint:** U242 T2 (= U235 Stage 4 + Stage 5) · **Owner:** Jo
**Status:** Design — pending review before implementation plan

## 1. Context & goal

U235 shipped the RAG infrastructure (Stages 0–3): sanitised full-body email chunks
(`email_rag_chunks`, 130k rows), `nomic-embed-text` embeddings, hybrid lexical+cosine
retrieval, and Sonnet synthesis — exposed as `/api/research/ask` (tuned in U242 T1).

This spec is the **destination**: a distilled, browsable **counterparty cultural memory**.
The primary deliverable (Jo's choice) is **counterparty dossiers** — a per-entity profile of
who each correspondent is, our history with them, spend, and open threads — for **everyone we
correspond with**, surfaced on a browsable page.

### Inherited locked decisions (from U235)
- **O2** — Structured extraction store (entities + facts + relationships), **not** a knowledge graph.
- **O3 / D2** — Owner-unified memory spanning all realms; Jo is the sole owner-level consumer.
  Work/personal surfaces stay segregated (RLS + explicit realm filter in SQL — never RLS alone).
- **D1** — Hybrid lexical-first retrieval on `real[]` vectors; no pgvector migration.
- **D3** — Injection defence is architectural: only RAG-safe text to the model, synthesis LLM has
  **no tools**, retrieved content delimited as untrusted, realm-scoped at the SQL layer.
- **AGENTS.md** — constrained JSON generation (OutcomeObject), `SET LOCAL app.current_entity`
  before writes, signed event payloads, pre-push entropy scan.

### Verified starting state (2026-06-05)
- No counterparty registry exists. `entities` holds only the 4 top-level business entities.
  Counterparties live scattered: `vendor_invoice_lines` (vendor names), `bank_transactions`
  (payee narratives), `emails.from_address`, `guest_contacts`, `wa_contacts`.
- `emails`: 74,636 rows. Useful cols: `from_address, from_name, account, realm, body_text_safe,
  received_at, classification, entity_id`. **No recipient/direction column** — table is
  inbound-centric (sent mail lives in `documents`). So "did we reply" is not directly available;
  relationship strength is inferred from inbound volume + diversity + financial linkage.
- `classification` is **not** a usable filter: 69,483/74,636 are `backfill` (unclassified). Noise
  filtering must be heuristic.
- Correspondent universe: **1,675 domains / 5,901 addresses**. Mixed: real orgs
  (`jrf.lls.com`=J&R, `forestproduce.com`, `westcountry.co.uk`), own domain
  (`malthousetintagel.com`, exclude), automated platforms (`collinsbookings` 6,240 from one
  address; `hotel-email.com`; `dext` notifications). **Signal: real orgs have many human
  addresses; automated senders are 1 address × high volume.**

## 2. Architecture (Hybrid — approach C)

```
emails ──► [1] Registry build (deterministic SQL)
                 │  org = domain, person = address; noise-flag; financial link
                 ▼
            counterparties ───────────────► [3] /app/memory page (owner-only)
                 │                                  directory + dossier view
   email_rag_chunks + financials                    ▲
                 ▼                                   │
            [2] Distillation worker ──► counterparty_dossier
                 eager subset (Sonnet) + lazy on-demand + incremental
```

Three isolated units, each independently testable:
- **Registry** — pure SQL/data, no LLM. Input: `emails` (+ fuzzy link to vendors/bank). Output: `counterparties`.
- **Distillation** — LLM worker. Input: a counterparty + its `email_rag_chunks` + financial facts. Output: `counterparty_dossier`.
- **Page** — read-only UI over the two tables.

## 3. Data model

### `counterparties`
| col | type | notes |
|---|---|---|
| id | bigserial PK | |
| kind | text | `'org'` \| `'person'` |
| display_name | text | org: best name from `from_name`/domain; person: name/email |
| domain | text | org's domain; person's domain |
| primary_email | text | person only |
| addresses | text[] | all addresses seen at this org |
| parent_org_id | bigint NULL | person → owning org |
| realms | text[] | realms this correspondence appears in (work/personal/owner) |
| is_automated | boolean | heuristic flag; hidden by default, not deleted |
| email_count | int | inbound volume |
| first_seen / last_seen | timestamptz | from `received_at` |
| linked_vendor | text NULL | best fuzzy match into `vendor_invoice_lines` |
| linked_confidence | real | 0–1; **reviewable, not authoritative** |
| signal_score | real | volume + has-financial + recency (drives eager selection & sort) |
| on_watchlist | boolean | Jo can pin |
| created_at / updated_at | timestamptz | |

Unique key: `(kind, coalesce(primary_email, domain))`. RLS: realm policy mirroring `emails`
(owner sees all; work cannot read personal-only rows). `realms` array gates non-owner surfaces.

### `counterparty_dossier`
| col | type | notes |
|---|---|---|
| id | bigserial PK | |
| counterparty_id | bigint FK → counterparties | unique |
| summary | text | distilled narrative |
| key_facts | jsonb | `[{fact, citation_email_id}]` |
| financials | jsonb | `{total_spend, n_invoices, last_payment_date, currency}` — **DB-derived, not LLM** |
| open_threads | jsonb | `[{subject, last_activity, status, email_id}]` |
| people | jsonb | org only: `[{name, email, role}]` |
| citations | bigint[] | email ids backing the summary |
| model | text | e.g. `claude-sonnet-4-6` |
| realms | text[] | inherited from counterparty |
| distilled_through | timestamptz | = counterparty.last_seen at distillation time (incremental water-mark) |
| generated_at | timestamptz | |

Re-distill when `counterparties.last_seen > dossier.distilled_through`.

## 4. Component 1 — Registry build

`scripts/build-counterparty-registry.sql` (idempotent upsert), invokable standalone and from cron.

- **Orgs:** group `emails` by `lower(split_part(from_address,'@',2))`; aggregate count, first/last
  seen, distinct addresses, `array_agg(distinct realm)`.
- **People:** group by `lower(from_address)`; link to org by domain.
- **Exclusions:** own domain (`malthousetintagel.com`), empty/malformed addresses.
- **`is_automated` heuristic** (flag, don't delete):
  - local-part matches `^(no-?reply|do-?not-?reply|notifications?|mailer|bounce|updates?|news|
    newsletter|marketing|alerts?|postmaster|mailer-daemon)` , OR
  - single distinct address at the domain with `email_count > 50`, OR
  - domain in a small curated bulk-ESP denylist (sendgrid/mailchimp/etc — seed list in spec).
- **Financial link (best-effort, reviewable):** trigram match `display_name`/`domain`
  → distinct vendor names in `vendor_invoice_lines`; store best match + `linked_confidence`.
  Bank linkage deferred to P2 (payee narratives are noisier — see recon lessons).
- **`signal_score`** = w1·log(email_count) + w2·has_financial_link + w3·recency. Drives eager
  selection and default sort. Weights are constants in the script (tunable).

Tests: own-domain excluded; `jrf.lls.com`/`forestproduce.com` kept as orgs; `collinsbookings`/
`dext`/`no-reply@*` flagged automated; realm arrays correct; person→org parent links correct.

## 5. Component 2 — Distillation worker

`scripts/distill-dossiers.py` (mirrors the `u65` embedding worker), cron-driven "dreaming"
style; plus a lazy endpoint for on-demand.

**Per counterparty:**
1. Gather that entity's `email_rag_chunks` (join `emails` by address/domain, realm carried),
   most-recent-first, capped to a token budget.
2. Compute `financials` **in SQL** from linked `vendor_invoice_lines` (+ bank in P2) — **never let
   the LLM invent figures** (financial-recon discipline: dedup before summing, cross-foot).
3. Build a constrained prompt: RAG-safe chunk text **delimited as untrusted data**, financial
   facts as trusted context; ask for summary + key_facts + open_threads + people, JSON-schema
   constrained (OutcomeObject), every claim citing an `email.id`.
4. Call **Sonnet** (existing `_vault_read("anthropic")` path); no tools. Parse, validate schema,
   upsert dossier with `distilled_through = last_seen`.

**Selection / scheduling:**
- **Eager pass:** counterparties where `linked_vendor IS NOT NULL` **OR** `email_count ≥ 20`
  **OR** `on_watchlist` **AND** `NOT is_automated`. (Threshold N=20 tunable.)
- **Lazy:** `POST /api/memory/dossier/{id}` distils on demand if missing/stale, caches.
- **Incremental:** nightly off-peak cron distils up to `BATCH=25` stale/new entities per run,
  honouring the budget split / £3-day cap (`quota_allocations`). Local `qwen2.5:7b` is a deferred
  option for the long tail.

Security tests: an injection-probe email in the corpus cannot alter the dossier output; work-realm
context cannot pull personal chunks; citations resolve to real emails; financials equal an
independent SQL recomputation.

## 6. Component 3 — Browsable page (`/app/memory`, owner-only)

- **Directory:** searchable/filterable (name, realm, has-spend, automated on/off toggle, watchlist),
  sortable by signal_score / spend / last_seen. Paginated registry pattern (reuse Mission Control /
  emails-browser components).
- **Dossier view:** narrative + financial summary + people + open threads + cited emails (clickable
  through to the existing emails browser). "Refresh" triggers the lazy endpoint.
- **API:** `GET /api/memory/counterparties` (filters), `GET /api/memory/counterparty/{id}` (dossier).
- **Access:** owner realm + Authelia owner tier (`/build`/`/admin`), consistent with other
  owner-only surfaces.

## 7. Realm & security (D2/D3)

- New tables get RLS realm policies (mirroring `emails`); the registry/distillation workers run
  owner-context but **explicitly** filter realm in SQL (the U147 realm-evaporation trap).
- Only `email_rag_chunks` / `body_text_safe` text reaches any prompt (AGENTS.md Rule 4).
- Synthesis LLM has no tools, no exfil path; retrieved content delimited as untrusted.
- Financials are DB-derived and cross-footed; bank sums dedup exact-duplicate rows first
  (`bank_transactions` known-dup lesson).

## 8. Phasing (one spec → one plan, three phases)

- **P1 — Registry:** tables + build script + RLS + tests. Ship the deterministic directory.
- **P2 — Distillation:** dossier store + worker + eager pass + lazy endpoint + incremental cron +
  security/financial tests.
- **P3 — Page:** `/app/memory` directory + dossier view + API.

## 9. Non-goals (YAGNI)

- No knowledge graph (O2). No pgvector migration (D1).
- No sentiment / "relationship-health" scoring in the MVP (deferred — noisy, not requested).
- No auto-merge of fuzzy financial links (reviewable only; never authoritative).
- No write-back/actions from the page (read-only).
- No new sanitiser/embedding work — reuse Stages 0–3.

## 10. Tunable parameters (defaults, not blockers)

| param | default | where |
|---|---|---|
| eager email threshold N | 20 | registry/selection |
| automated single-address volume | 50 | registry heuristic |
| distillation batch / cron run | 25 | worker |
| distillation model | claude-sonnet-4-6 | worker (qwen tail deferred) |
| chunk token budget per dossier | ~6k tokens | worker |
