# Karpathy phase — vault wiki compilation

> Subset of Phase 5 in SPEC §10. Not Phase 5 in its entirety.
> "Karpathy" in the spec specifically names the wiki-index pattern
> (SPEC §10.3, lines 4930–4969): pre-compile expensive business
> context into ~one-page Markdown articles, regenerate nightly, and
> always start a conversation with `read_wiki_index()`.
>
> Out of scope here: research pipeline, full hybrid RAG, cross-encoder
> reranking, playground agent, photo migration, weekly news. Those
> share Phase 5 but are independent deliverables and should be their
> own sprints.

---

## 0 · Why a separate plan

The Karpathy piece is the cheapest, highest-leverage thing in Phase 5
and has almost no dependency on the rest of it. It needs:

- Vault MCP (already specced for Phase 3, §8.6, port 8007)
- Read-only Postgres access from n8n (already in place)
- Haiku for compilation (already in stack)
- An n8n schedule trigger

It does **not** need Qdrant, embeddings, cross-encoder, sparse vectors,
or any retrieval pipeline. Treat it as a "compile-once, read-cheap"
layer that sits in front of all future retrieval work and may absorb a
fair chunk of what would otherwise hit RAG.

---

## 1 · Principles

| # | Principle |
|---|---|
| K1 | **Compile, don't retrieve.** Nightly Haiku pass writes Markdown. Read path is `cat`, not vector search. |
| K2 | **index.md fits in one context window.** Hard ceiling: 3,000 tokens. Lint enforces it. If it grows past, split an article, don't loosen the limit. |
| K3 | **Each article is one page.** ~800–1,500 tokens per `Wiki/*.md`. One topic per file. Article names are stable — links from MEMORY.md and from index.md must keep resolving. |
| K4 | **Articles are derived, never edited by hand.** If Jo wants to add nuance, that goes in `Areas/` or `Resources/`; the compiler can be told to consult them, but `Wiki/` is regenerated from scratch every run. |
| K5 | **One failing article never blocks the others.** Per-article try/except in n8n; index.md notes "compiled / failed / stale" per row. |
| K6 | **Idempotent under no-data-change.** If source queries return the same rows as last run, skip the Haiku call and leave the file untouched. Saves tokens and keeps git diffs meaningful. |
| K7 | **Realm-aware.** Three realms are non-negotiable ([[project_realm_split]], [[feedback_realm_must_be_designed_in]]). Wiki articles declare their realm in frontmatter and the index groups by it; the Vault MCP refuses to expose a realm the caller isn't scoped to. |

---

## 2 · Article catalog (initial set)

The catalog is part of the plan, not the workflow. Adding/removing
articles is a deliberate decision, not a runtime choice.

| Slug | Realm | Source queries | Updated | Why this one |
|---|---|---|---|---|
| `malthouse-performance.md` | WORK | last 30d EPoS gross/food-GP%/covers/sessions; last 7d cash-up variance; occupancy + RevPAR | nightly | The single most asked-about thing |
| `estates-status.md` | WORK | all 7 properties — rent status, arrears days, compliance expiry windows | nightly | Replaces 80% of "where's my rent at" Qs |
| `cashflow-snapshot.md` | WORK | latest `cashflow_forecast` per entity, overdue invoices, outstanding rent | nightly | Top-of-mind weekly |
| `staff-notes.md` | WORK | non-sensitive staff context, rota anomalies, leaver/joiner this month | weekly | Low churn — weekly is fine |
| `suppliers-snapshot.md` | WORK | top 10 vendors by 90d spend, payment terms, last-invoice date | weekly | Buying/negotiation context |
| `personal-finance.md` | OWNER | personal accounts summary, credit card outstanding ([[project_credit_cards]]), upcoming DDs | nightly | Belongs in OWNER realm, never WORK |
| `properties-personal.md` | OWNER | Castle Rd / Salutations / Olde Malthouse mortgage state ([[project_properties_mortgages]]) | weekly | Slow-moving |
| `family-snapshot.md` | FAMILY | children — term dates, upcoming medical/school items | weekly | FAMILY-only realm |
| `index.md` | (all) | catalog of the above + last-compiled-at + realm tags | every run | The Karpathy entrypoint |

Anything not on this list is **not** in `Wiki/`. New articles get added
via PR to this plan, not invented in the workflow.

---

## 3 · n8n workflow — `karpathy-wiki-compile`

```
Schedule trigger (01:00 daily)
        │
        ▼
Code: build job list (realm × article)
        │  filters out weekly articles on non-Monday runs
        ▼
SplitInBatches (batchSize: 1, continueOnFail: true)
        │
        ├─► Postgres: run article's source queries
        │           │
        │           ▼
        │   Code: hash the result set
        │           │
        │           ▼
        │   IF hash == last_hash from `wiki_article_state` table?
        │     ├─ yes ─► mark "unchanged", skip Haiku, continue
        │     └─ no  ─► continue to Haiku
        │           │
        │           ▼
        │   Anthropic (Haiku 4.5): compile per template (§4)
        │           │
        │           ▼
        │   Code: token-count the output (tiktoken or claude-tokenizer)
        │           │
        │           ▼
        │   IF tokens > article ceiling? fail this article, continue
        │           │
        │           ▼
        │   HTTP → Vault MCP /write_note  (Wiki/<slug>.md)
        │           │
        │           ▼
        │   Postgres: UPSERT wiki_article_state(slug, hash, compiled_at, tokens, status)
        │
        ▼
After all articles finish:
        │
        ▼
Code: build index.md from wiki_article_state
        │  (one section per realm, one line per article: slug,
        │   one-sentence summary from frontmatter, compiled_at,
        │   status indicator). Token-count it. Hard fail if > 3000.
        │
        ▼
HTTP → Vault MCP /write_note  Wiki/index.md
        │
        ▼
Telegram (only if any article status != ok):
   "Karpathy compile finished. Failed: estates-status (1200 token cap exceeded).
    Stale: family-snapshot (last ok 4d ago). Index: 2,140 tk."
```

Schema for the small state table (V-migration goes with this sprint):

```sql
CREATE TABLE wiki_article_state (
    slug          TEXT PRIMARY KEY,
    realm         TEXT NOT NULL,
    source_hash   TEXT,
    token_count   INT,
    status        TEXT,        -- ok | unchanged | failed | stale
    last_error    TEXT,
    compiled_at   TIMESTAMPTZ,
    last_ok_at    TIMESTAMPTZ
);
```

This is also the table the index.md compile reads from — no need for
a second source of truth.

---

## 4 · Per-article compilation template

One prompt shape, parameterised. Keeps Haiku usage cacheable
([[feedback_prompt_cache_thresholds]] — Haiku needs ~5,000+ static
tokens before caching engages, so the system prompt should carry the
spec/rules and the user message should carry only the data).

System prompt (static — cacheable across all articles in one run):

> You compile one-page Markdown articles for an Obsidian wiki.
> Every article begins with YAML frontmatter (slug, realm,
> compiled_at, source_summary). The body is **at most 1,200 tokens**.
> Lead with the single most important number. Use a tight table for
> per-item rows. End with a one-line "What changed since last week"
> if you can infer it from the data; otherwise omit. No filler, no
> "here's the article" preamble, no concluding paragraph. Write as
> if Jo is reading it on his phone in the back of the pub.

User prompt (per article):

```
Slug: malthouse-performance
Realm: WORK
Date: 2026-05-19

Source data:
<json blob of all the rows the n8n step pulled>

Compile.
```

Token budget per article enforced post-hoc in n8n (§3 step "token-count
the output"). If Haiku blows the budget, the article fails and the old
file stays — better stale than truncated.

---

## 5 · The index.md (the Karpathy constraint)

This is the only file in `Wiki/` Claude is guaranteed to read. It must:

- Be deterministic (built from `wiki_article_state` in code, not Haiku)
- Group by realm so a realm-scoped read returns only relevant rows
- Show staleness — `compiled_at` per row, with `⚠` if older than the
  article's expected cadence × 2
- Include a one-sentence summary per article (cached in frontmatter
  of the article itself — written by Haiku once, lifted by the index
  builder)
- Cap at 3,000 tokens. Hard fail the run if exceeded — don't ship a
  truncated index.

Sketch:

```markdown
# Wiki index — compiled 2026-05-19 01:04

## WORK
- [malthouse-performance](malthouse-performance.md) · 2026-05-19 ·
  Pub trading. Last 30d gross, food GP, occupancy.
- [estates-status](estates-status.md) · 2026-05-19 ·
  7 rental properties. Rent state, arrears, compliance windows.
- ...

## OWNER
- [personal-finance](personal-finance.md) · 2026-05-19 ·
  Personal accounts, credit cards, upcoming DDs.
- ...

## FAMILY
- [family-snapshot](family-snapshot.md) · 2026-05-13 ⚠ stale ·
  Children — term dates, school/medical items.
```

The `⚠ stale` marker matters more than the article being perfectly
fresh — better that Claude knows it's reading old context than that
the freshness is hidden.

---

## 6 · Read-side wiring

The compile workflow is half the story. The other half is making sure
Jo actually benefits from it.

1. **Vault MCP `read_wiki_index()`** already exists in the spec
   (§8.6). Confirm it's deployed and that it filters by realm based on
   the caller's identity.
2. **MEMORY.md amendment.** Add a `§` section pointing at the wiki:
   `KARPATHY: Start every business conversation with read_wiki_index().
   Articles are nightly-compiled — never edit Wiki/* by hand.`
3. **Conversation templates** in SPEC §8.5 should be updated to drop
   the "paste Metabase export" step in favour of "let Claude read the
   relevant wiki article."
4. **Bot responder** ([[project_u66_telegram_bot]]). The Telegram bot's
   Sonnet path should call `read_wiki_index()` on every fresh
   conversation thread so day-to-day Telegram Qs benefit too, not just
   Claude.ai.

---

## 7 · Bootstrap

Day-0 needs articles to exist before the workflow can update them.
Two options:

| Option | Pros | Cons |
|---|---|---|
| **Run the workflow manually once with all source hashes empty** | Same path as nightly — no special case | First run will fail-and-recover article-by-article; expect noise |
| **Seed with hand-written stubs, then let nightly take over** | Clean first index | Drift risk if a stub gets baked into someone's mental model |

Recommend option 1 — same code path means we test the real thing on
day one. Accept the noisy first Telegram.

---

## 8 · Observability

- `wiki_article_state` table is the source of truth — surface it on
  Mission Control ([[project_dashboard_refactor]]) as a small widget:
  per-article status dot + last-ok-at. Anything stale > 48h flips red.
- Telegram only on degradation, not on every run
  ([[feedback_telegram_heartbeat]]).
- Workflow emits a `wiki.compile.finished` event the heartbeat watcher
  can use as its liveness signal; if missed for 36h, heartbeat
  Telegrams.

---

## 9 · Validation checklist

```
[ ] V-migration creates wiki_article_state, baseline empty
[ ] n8n workflow imported via workflow_history pattern
    ([[feedback_n8n_workflow_history_runtime]] — edit workflow_entity
    only, plus a new workflow_history row, plus repoint activeVersionId)
[ ] No literal `}}` inside any n8n expression body
    ([[feedback_n8n_expression_braces]])
[ ] Manual trigger compiles all 8 articles + index.md
[ ] index.md is < 3000 tokens (lint passes)
[ ] Each article respects its per-article token cap
[ ] Re-running with no DB changes skips Haiku for every article
    (verify in wiki_article_state.status = 'unchanged')
[ ] Forcing one article to fail (bad query) doesn't block the others;
    index shows it as failed with last_ok_at preserved
[ ] Vault MCP `read_wiki_index()` returns only the realms the caller
    is scoped to
[ ] Telegram bot prepends `read_wiki_index()` and a referenced
    article on a sample question; answer references real data
[ ] Mission Control widget renders article state
[ ] Run nightly for 7 days; spot-check three articles for accuracy
    against the underlying SQL
[ ] No `Wiki/*.md` file is in git with hand edits (everything matches
    the compiler output for its source hash)
```

---

## 10 · What this plan deliberately does **not** include

- **Hybrid RAG / Qdrant.** Separate sprint. The wiki layer is meant to
  remove pressure from RAG, not to be RAG.
- **Cross-encoder reranking.** Same reason.
- **Research pipeline writing to `Resources/Research/`.** That's the
  *input* to future wiki articles, not part of this compile loop.
- **Auto-creation of new articles.** The catalog (§2) is explicit. New
  topics are a PR to this plan first, code change second.
- **Editing `Areas/`, `Projects/`, `System/`.** Vault MCP write
  whitelist (SPEC §8.6) already blocks this; this plan doesn't widen
  it.

---

## 11 · Open questions for Jo

1. **Wiki/index.md token budget — is 3,000 right?** Spec says yes;
   confirm before we lint-fail at that number.
2. **Realm scoping of `read_wiki_index()`.** Does the MCP caller's
   realm come from Authelia identity (preferred) or a per-MCP-server
   env var? Spec §8.6 is silent; the realm-split memory says identity.
3. **Should the Telegram bot read the wiki on every message or just
   on conversation start?** Per-message inflates cost; per-conversation
   risks staleness mid-thread.
4. **Sprint number / decision file.** I haven't assigned a U-number
   ([[feedback_check_sprint_number_first]]) — pick one against
   `home_ai/decisions/` and `home_ai/sprints/` before renaming this
   plan from `karpathy-phase.md` to `uNN-karpathy-phase.md`.
