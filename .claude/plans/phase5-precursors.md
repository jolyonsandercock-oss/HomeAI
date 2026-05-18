# Phase 5 precursors — audit and run-up plan

> Phase 5 in SPEC §10 = weeks 25–30 of the original plan: research
> agent, coding assistant, full hybrid RAG, Karpathy wiki compile,
> photo migration, weekly news, playground agent.
>
> Question this plan answers: **what has to be true before Phase 5
> opens cleanly, what's already true, and what's the minimum workflow
> from here to there?**
>
> Caveat: this audit is built from memory + the spec. Items marked
> `(verify)` need a quick check against the running system before
> they're committed.

---

## 1 · How "precursor" is defined here

Two senses, separated deliberately:

1. **Hard precursor** — Phase 5 deliverables literally don't work
   without it. e.g. wiki compile needs `Wiki/` to exist in a real
   vault that has a real MCP write surface.
2. **Soft precursor** — assumed by the spec but Phase 5 work-arounds
   exist. e.g. weekly news digest assumes WhatsApp bridge data is
   present in the comms digest, but it can launch without it.

Hard precursors block. Soft precursors get noted but don't gate.

---

## 2 · Audit: spec deliverable → current state → gap

### Phase 1 — event backbone

| Deliverable | State | Phase 5 dependency? |
|---|---|---|
| PostgreSQL + RLS + init schema | shipped (we're at V73, [[project_credit_cards]]) | hard — everything reads from it |
| Vault running, secrets stored | shipped (memory: VAULT_TOKEN everywhere) | hard |
| Email ingestion classified → DB | shipped ([[project_homeai.md]]) | hard — RAG indexes emails |
| n8n event router | shipped | hard |
| Dead-letter queue + thresholds | shipped (memory bumped DL 5→50 in [[feedback_report_ingestion_noop_skip_bug]]) | soft |

**Phase 1 verdict:** done.

### Phase 2 — finance, fitness, HR

| Deliverable | State | Phase 5 dependency? |
|---|---|---|
| Vault auto-unseal (systemd) | `(verify)` — no memory entry | soft — annoying if a reboot needs human, but Phase 5 doesn't break |
| Authelia SSO across UIs | shipped ([[feedback_authelia_cookie_domain]] resolved 2026-05-18) | hard — vault-MCP realm scoping rides on Authelia identity |
| Model evaluator + benchmarks | `(verify)` — qwen U7 optimisation work happened ([[project_qwen_u7_optimisation]]) but no entry for the dashboard or n8n workflows A/B/C | soft — Phase 5 wants Haiku/Sonnet, not local models in the critical path |
| NatWest/RBS Open Banking | `(verify)` — credit-card data came via PDF+CSV ([[project_credit_cards]]), not OB API. Likely not done. | soft for Phase 5; hard for cashflow accuracy |
| Bank reconciliation pipeline + Sonnet explainer | `(verify)` — Xero ingest exists ([[project_u128_xero]]) and auto-forwards orphans to Dext, but a reconciliation _explainer_ isn't called out | soft — Phase 5 doesn't depend on it; cashflow wiki article does |
| Rent reconciliation tracker | `(verify)` — properties + mortgages in DB ([[project_properties_mortgages]]), unclear if rent_payments status flow is wired | hard for Karpathy wiki estates-status article |
| Pub cashflow forecast pipeline | `(verify)` | hard for Karpathy cashflow-snapshot article |
| Caterbook occupancy panel | shipped (U34 fixed double-count, [[feedback_caterbook_revenue]]) | hard for Karpathy malthouse-performance article |
| Garmin pipeline + Sunday digest | `(verify)` — no memory entry | soft — personal-finance article doesn't need fitness; nice-to-have only |
| HR/staff DB + holiday calc + compliance | `(verify)` — Tanda timesheets came in U62-64, but holiday/compliance unclear | hard for Karpathy staff-notes article |
| Atlas migrations | shipped (V73 baseline) | hard — Karpathy needs a `wiki_article_state` table via Atlas |
| AI worker drift alerting | `(verify)` | soft |

**Phase 2 verdict:** patchwork. The fitness and HR and OB pieces look skipped, but the *parts Karpathy needs* (occupancy, rent, cashflow) are partially there. Need a targeted "Phase 2 finisher" sprint focused only on what wikis need.

### Phase 3 — UX, MCPs, vault

| Deliverable | State | Phase 5 dependency? |
|---|---|---|
| Google Calendar sync (3 cals) | shipped (U62-64) | soft |
| Task engine | shipped (U62-64) | soft |
| Property database | shipped (memory: properties + mortgages) | hard for estates wiki |
| Document control + versioning | shipped (U61 docs, U68 classifier, U62-64 Paperless) | hard — Phase 5 RAG indexes documents |
| Scanner → Drive → OCR → Postgres | shipped (pdfplumber on :8003, [[feedback_pdfplumber_service]]) | hard |
| **PostgreSQL MCP @ 8005** | **divergent** — memory says canonical MCP is homeai-mcp at 8765 ([[project_mcp_standard]]). One surface, not three. | **decision needed** before Phase 5 wires more MCP-aware features |
| **Obsidian Vault MCP @ 8007** | likely subsumed under homeai-mcp at 8765 OR not built yet `(verify)` | hard for Karpathy — wiki compile writes via MCP |
| **MarkItDown @ 8006** | `(verify)` — pdfplumber covers PDFs; MarkItDown adds audio/image/Word/YouTube | soft for Karpathy; hard for full RAG (audio notes, screenshots) |
| Playwright service | `(verify)` | soft for Karpathy; hard for research pipeline (web fetch) |
| Next.js dashboard v2 | shipped (U31/32/33), refining in U84/U85 | soft |
| Self-test suite | `(verify)` — Mission Control is shipped but the formal 30-test diagnostic? not in memory | soft |
| **Obsidian vault filesystem (PARA layout)** | `(verify)` — no memory entry. This is the foundation Karpathy writes into. | **hard — critical path** |
| Authelia SSO fully configured | shipped | hard |

**Phase 3 verdict:** most Phase 3 *outcomes* exist but the *plumbing the spec assumes* is divergent (MCP architecture) or missing (vault filesystem). Karpathy cannot start until vault + MCP are settled.

### Phase 4 — comms

| Deliverable | State | Phase 5 dependency? |
|---|---|---|
| WhatsApp Baileys bridge | `(verify)` — no memory entry | soft — RAG can index it later if it lands |
| Blacklist | `(verify)` | soft |
| Unified comms digest | partial — Telegram bot exists (U66, [[project_u66_telegram_bot]]), email digest format canonical ([[feedback_email_format_canonical]]) | soft |
| Pub document store | shipped-ish (U61/U68/U128 documents) | hard for RAG |
| Telegram 2FA + alert channel | shipped (heartbeat, bot, [[feedback_trusted_inbox_and_sender]]) | hard for bot-led Karpathy reads |

**Phase 4 verdict:** non-blocking. WhatsApp not landing doesn't stop Phase 5 starting; Karpathy doesn't index WhatsApp.

---

## 3 · Hard precursor list (the actual gate)

Distilling §2 into the only things that *must* be done before opening Phase 5:

1. **Vault filesystem stood up** under PARA layout (`Inbox/`, `Projects/`, `Areas/`, `Resources/`, `Archives/`, `Wiki/`, `Daily/`, `System/`). Backed by Obsidian Git plugin so it's version-controlled.
2. **MCP architecture decision** (see §5) — keep `homeai-mcp @ 8765` as the single surface, or split into spec's three? Either is fine but the wiki compile pipeline writes into one of them, so it has to be settled.
3. **Vault MCP write surface** — `write_note` tool restricted to `Inbox/`, `Wiki/`, `Resources/Research/`, `Daily/`. Whichever MCP server hosts it.
4. **Realm scoping on the Vault MCP** — caller identity → realm filter. The realm split is locked ([[project_realm_split]]); MCP must honour it.
5. **`wiki_article_state` migration applied** (V74 or whichever is next).
6. **Source-data coverage for the initial wiki catalog** — specifically:
   - `epos_daily_reports` populated (already true)
   - rent_payments with status field flowing (Phase 2 rent tracker — `(verify)`)
   - `cashflow_forecast` table populated per entity (Phase 2 — `(verify)`)
   - staff table with holiday/compliance fields (Phase 2 HR — `(verify)`)
   - credit-card outstandings queryable ([[project_credit_cards]] — V73, true)
   - properties.compliance_expiry fields (`(verify)`)
   Where these are missing, the corresponding wiki article either lands later or compiles into "no data yet".
7. **`read_wiki_index()` and `read_note()` exposed by Vault MCP and tested against Claude.ai SSE endpoint** (or whatever transport the homeai-mcp surface uses).
8. **Bot responder uses Sonnet** (memory confirms [[project_u66_telegram_bot]] does) — prompt caching kicks in at 1024 tokens for Sonnet, so cached system prompt + wiki index makes economic sense ([[feedback_prompt_cache_thresholds]]).

Soft precursors (will *help* Phase 5 but don't gate it): Garmin pipeline, OB API, MarkItDown, WhatsApp bridge, reconciliation explainer, model drift alerting.

---

## 4 · Critical-path workflow (proposed sprint sequence)

The shortest path from current state to "Phase 5 open." Five sprints, sized so each is independently shippable and reversible.

```
┌──────────────────────────────────────────────────────────────┐
│  S1  Vault & MCP foundation                                  │
│      Stand up /mnt/ssd/obsidian-vault with PARA layout.      │
│      Decide MCP topology (§5). Wire Vault MCP write tools    │
│      with realm scoping. Smoke test from Claude.ai.          │
│      Output: read_note() + write_note() + read_wiki_index()  │
│              all callable, realm-respecting.                 │
│                                                              │
│      Blocks: everything below.                               │
└──────────────────────────────────────────────────────────────┘
              │
              ▼
┌──────────────────────────────────────────────────────────────┐
│  S2  Phase 2 finisher — only what Karpathy reads             │
│      Targeted, not the full Phase 2. Goal: every wiki        │
│      article in §2 of [[karpathy-phase]] has live SQL it     │
│      can compile from.                                       │
│                                                              │
│      Sub-tasks (each landing as its own PR / migration):     │
│        a) rent_payments status flow live for 7 properties    │
│        b) cashflow_forecast view per entity (Trading,        │
│           Estates) populated nightly                         │
│        c) staff table holiday_entitlement + statutory calc,  │
│           plus compliance_expiry fields                      │
│        d) properties.compliance_expiry hydrated from         │
│           existing documents where possible; gaps logged     │
│                                                              │
│      Articles whose data is still empty after S2 compile     │
│      to "no data yet — pending S2 sub-task X" rather than    │
│      blocking the whole compile.                             │
└──────────────────────────────────────────────────────────────┘
              │
              ▼
┌──────────────────────────────────────────────────────────────┐
│  S3  Karpathy phase                                          │
│      Per [[karpathy-phase]] plan. Build the compile          │
│      workflow, the state table, the index.md generator,      │
│      validation, observability. Bootstrap with manual run.   │
│                                                              │
│      Exit criterion: 7 nightly runs in a row succeed;        │
│      Telegram bot conversations measurably benefit from      │
│      read_wiki_index().                                      │
└──────────────────────────────────────────────────────────────┘
              │
              ▼
┌──────────────────────────────────────────────────────────────┐
│  S4  Phase 5 RAG plumbing                                    │
│      Qdrant up, collections with dense+sparse, embedding     │
│      pipeline indexing emails/invoices/documents,            │
│      cross-encoder reranker service. NO consumer agent yet.  │
│                                                              │
│      Built last so the question "did we actually need this   │
│      given the wiki layer?" is answerable from real Karpathy │
│      usage data in S3.                                       │
└──────────────────────────────────────────────────────────────┘
              │
              ▼
┌──────────────────────────────────────────────────────────────┐
│  S5  Phase 5 consumer agents                                 │
│      Research pipeline (uses S4 RAG + Playwright + Vault     │
│      write_note → Resources/Research/).                      │
│      Coding assistant pipeline (Github integration).         │
│      Weekly industry news briefing.                          │
│      Playground agent (sandbox + Vercel auto-deploy).        │
│      Photo migration (orthogonal — can slot in any time).    │
└──────────────────────────────────────────────────────────────┘
```

Notes on ordering:

- **S1 before everything else.** Without the vault filesystem and a settled MCP topology, S3 has no surface to write to and S5 agents have no `Resources/Research/` destination.
- **S2 before S3 but only the slices Karpathy uses.** Don't get tempted into doing all of Phase 2; the parts that *don't* feed wiki articles (Garmin, OB, drift alerting) can land in parallel with later sprints.
- **S3 before S4** is the controversial call. Spec orders RAG first; this plan orders Karpathy first. Reason: the wiki layer may absorb 60–80% of the questions that would otherwise need RAG. Building it first surfaces what RAG actually needs to cover — small slice instead of "index everything."
- **Photo migration is orthogonal.** It's a Phase 5 deliverable but doesn't sit on this critical path. Schedule it whenever HDD time is convenient.

---

## 5 · The MCP topology decision

[[project_mcp_standard]] says `homeai-mcp @ 8765` is the canonical
external AI surface and new AI-readable data should be wired via
slugs/resources there. SPEC §8.6 says three separate MCP servers
(postgres @ 8005, MarkItDown @ 8006, vault @ 8007).

These two conflict. Pick one before S1:

| Option | Pros | Cons |
|---|---|---|
| **A · Single homeai-mcp** (memory-current) | One surface; one auth path; consistent slug pattern; already operational | Diverges from spec; one process is a bigger blast radius if it crashes; mixing read-only DB tools with write-capable vault tools needs careful permissioning |
| **B · Three split servers per spec** | Smaller per-server surface area; aligns with spec; vault writes physically can't reach DB | More Docker services; three Authelia integrations; need to migrate consumers of homeai-mcp to whichever surface owns each resource |
| **C · Hybrid: keep homeai-mcp for DB resources, spin up vault-MCP @ 8007 as a new sibling** | Minimal disruption; vault writes isolated by process; existing MCP consumers untouched | Two surfaces to maintain |

Recommend **C**. The realm-split memory and the write-restriction
rules from SPEC §8.6 make a strong case for the vault surface being
its own process — and homeai-mcp already exists and works.

This is the one decision that must be made by hand before S1 can start.

---

## 6 · What this plan deliberately defers

- All of Phase 4 WhatsApp work. Not blocking; defer.
- OB API. Defer behind S5.
- Garmin pipeline. Defer behind S5 (or skip entirely if no longer wanted).
- Vault auto-unseal. Address opportunistically.
- Self-test suite v2 (the 30-test diagnostic component). Mission Control covers the visible bits; the formal suite is a polish item.
- Full model evaluator dashboard with monthly benchmarks. The qwen U7 work showed the local-model tiering pays off ([[project_qwen_u7_optimisation]]); a formal benchmark workflow can wait.

---

## 7 · Verification checklist (before S1 kicks off)

Run these against the actual system; replace `(verify)` markers in §2:

```
[ ] ls /mnt/ssd/obsidian-vault → exists? PARA folders present?
[ ] homeai-mcp at 8765 — list its current tools/resources; does any
    cover read_note / write_note?
[ ] SELECT max(version) FROM atlas_schema_revisions → confirms V73
    baseline; pick next free V-number for wiki_article_state
[ ] SELECT count(*) FROM rent_payments WHERE expected_date >
    CURRENT_DATE - INTERVAL '30 days' → is the rent tracker actually
    populating?
[ ] SELECT * FROM cashflow_forecast ORDER BY generated_at DESC LIMIT 1
    → does the table exist? does anything write to it?
[ ] SELECT column_name FROM information_schema.columns
    WHERE table_name='staff' → holiday_entitlement / compliance
    fields present?
[ ] SELECT count(*) FROM properties WHERE compliance_expiry IS NOT NULL
[ ] Vault auto-unseal: systemctl status vault-autounseal
[ ] Authelia identity → MCP caller identity: does the homeai-mcp
    surface know who's calling?
```

Each `[ ]` flips to known-state in S0 (the audit pass) so S1 starts
on solid ground.

---

## 8 · Open questions for Jo

1. **MCP topology** — confirm Option C in §5 (recommended) or pick
   another. This is the single biggest blocker.
2. **Phase 4 WhatsApp — kill or postpone?** If not landing soon,
   write it out of the digest expectations now rather than carrying
   the dependency.
3. **Garmin pipeline — still wanted?** Spec assumed personal fitness
   coaching; if Jo doesn't use it, drop the wiki article and the
   pipeline from scope.
4. **Which sprint number range?** Recent work is in the U120s+
   ([[project_u128_xero]]). Reserve a contiguous block for S1–S5
   against [[feedback_check_sprint_number_first]] before naming them.
