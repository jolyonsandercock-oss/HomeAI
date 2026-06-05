# U242 — Cultural Memory follow-ups (resume after reboot)

Status: PLANNED · Created 2026-06-05 · Follows U235 (RAG live) · Owner: Jo

Resume point after the reboot. U235 shipped the RAG infra: emails (130k sanitised
chunks), invoices (21,720 lines, amount-enriched), documents — all embedded
(nomic-embed-text) and queryable via build-dashboard `POST /api/research/ask`
(hybrid FTS+cosine + Sonnet, realm-filtered). Invoice queries are excellent.

## T1 — Email RAG retrieval quality (the quick win) ⭐ start here
**Problem (diagnosed in U235):** the lexical pass OR's all query terms, so common
words dominate. "Bidfresh statement of account" returns Flogas/Amazon because
"account" matches thousands. Invoice queries are unaffected (their terms are specific).

**Where:** `services/build-dashboard/main.py`, `/api/research/ask` — the `stopwords`
set (~L2446) and the `or_query` / FTS block (~L2451-2470).

**Do:**
- Expand stopwords with business-email noise: account, statement, invoice, ltd,
  limited, please, dear, hi, regards, thanks, email, order, payment, attached.
- Prefer rarer terms — drop/down-weight terms matching a huge doc count, or AND the
  2-3 most specific terms instead of OR-ing all.
- Raise the FTS candidate `LIMIT 50` (e.g. 200) so good hits aren't crowded out before
  the cosine rerank.
- **Do not regress invoices** — re-test both an invoice money question AND a vendor
  email question before/after.

**Deploy:** edit → `docker compose build build-dashboard` → recreate with the
Vault-harvested `POSTGRES_PASSWORD` (see `build-dashboard-image-rebuild` memory) →
test via `curl -H "X-Realm: owner" .../api/research/ask`. One rebuild.

## T2 — Distilled cultural memory (U235 Stage 4, the real payoff)
RAG today = search with a mouth. Build the distilled store: a scheduled worker that
extracts entities (vendors, people, recurring issues), decisions, disputes and
relationships from the corpus into a **structured store** (Jo's O2 choice: structured
extraction, NOT a knowledge graph) + a browsable page. Owner-realm, spans all data.

## T3 — Backup exit-3 (minor hygiene)
`backup-nightly.sh` exits 3 because 4 root-owned scripts (`vault-watchdog.sh`,
`u35-manual-data-freshness.sh` + `.bak`s) are unreadable by the `joly` cron user.
Run the backup cron as root, or add a restic `--exclude` for those files.

## Cross-refs (NOT in this sprint)
- **Superuser→service-role migration** = the #1 security task; home is
  **`U231-postgres-role-least-privilege.md`**. The half-baked attempt was reverted
  (`3ad638d`); proper recipe in `.claude/NEXT-SESSION.md` Carry-forward #1 +
  `.claude/decisions/2026-06-05-revert-broken-superuser-migration.md`. Do it properly,
  one coordinated session, before relying on RLS for backend services.

## Pre-reboot state (so resume is clean)
- Working tree clean; compose on superuser DSNs = reboot-safe.
- After reboot: `bash /home_ai/start.sh`, then follow `.claude/NEXT-SESSION.md`.
