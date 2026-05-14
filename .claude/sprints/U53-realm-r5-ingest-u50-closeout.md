# U53 — Realm R5 (Ingest Tagging) + U50 Closeout

**Prereqs**: U52 shipped (R1 + R2 live: 87 tables realm-policied, `home_ai.set_realm()` chokepoint, `REALM_ENFORCE=0` dormant on dashboard + bot). U50 *substantially* shipped already — V60 per-site labour, V61 due_date_extractions, scripts/u50-apply-feedback.sh (crond hourly, unapplied=0), scripts/u50-stale-ack.sh (crond 06:25 / 18:25), scripts/u50-due-date-haiku.sh (127 extractions logged, 105/145 PDFs = 72% have due_date — meets the ≥70% target). U50 sprint plan has never been formally marked done; this sprint closes it.

**Realm**: cross-cutting. Every track carries its own `**Realm:**` line per [[feedback_realm_must_be_designed_in]] and SPEC §2.5.

**Remote vs in-person**: 100% remote. No host sudo, no physical access, no Jo input. Suitable for unattended ~3h run.

**Why this sprint exists**: R1 labelled at insert-time but the ingest layer (google-fetch) never tags `realm` on the rows it writes — it relies on V64a triggers to compute realm from `account` or `entity_id`. That's correct *today* because every ingest path goes through one of the trigger-covered tables, but it's load-bearing: a future ingest source that writes to `events` or `documents` without an `account` field will fall through to the `owner` default and silently leak across realms. R5 makes the producer (google-fetch) explicit and adds a V67 immutability trigger so a row's realm can't be flipped post-insert except by an OWNER-credentialled override. Per [[project_realm_split]] R5 is the next realm phase that ships remote (R3 still blocked on tailscale-cert FQDN [[feedback_authelia_cookie_domain]]).

**Discipline carry-overs**:
- Rule #1 — verify before done. Every track ends with a SQL or curl gate that proves the producer is writing the right realm.
- Rule #5 — scripts-with-prompts beat copy-paste. T1 script must be idempotent (re-running the realm-stamp over already-tagged rows is a no-op).
- Rule #7 — audit consumers before replacing producer. T2's V67 trigger fires on UPDATE; check every UPDATE call-site against `emails.realm`, `documents.realm`, `vendor_invoice_inbox.realm` first (feedback applier, ack scripts, classifier). If any legitimate path needs to change realm post-insert, it must go through the `home_ai.realm_override(actor, table, id, new_realm, reason)` chokepoint and be audited.

## Tracks

### T1 — google-fetch realm tagging (~45 min)

**Realm**: cross-cutting (google-fetch writes to `emails`, `email_attachments`, `events`, `documents`, `vendor_invoice_inbox` — all realms touched).

**Why**: today these rows get their realm from V64a triggers that read `account` (emails) or `entity_id` (events/invoices). The trigger fallback is fine but it's a derived value — the producer should write it explicitly so a) the value travels with the row through the INSERT logs, b) future ingest sources can't silently bypass it, c) the V67 immutability check in T2 has something to compare against.

**Build**:
- `services/google-fetch/main.py`:
  - Add a module-level `_MAILBOX_REALM` dict mapping every known `account` value (the `account` column in `gmail_credentials`) to its realm: `info` / `admin` / `stay` → `work`; `jo` / `pounana` → `family`; `bot` → `owner`. Source of truth lives in SPEC §2.5; keep this dict in sync.
  - At every INSERT site in `poll_and_emit`, set `realm` explicitly from `_MAILBOX_REALM[account]` (panic-loud if unknown account — `raise ValueError(f"unknown mailbox account: {account}")`). Touches the 3 INSERTs into `events` (email.received, document.received per attachment) and the implicit-via-trigger writes to `emails`, `email_attachments`, `vendor_invoice_inbox`.
  - For event payloads, also stamp `payload->>'realm'` so downstream consumers (n8n, classifier) don't have to re-derive.
- One-shot backfill: `scripts/u53-r5-realm-backfill.sh` that audits the last 30 days of `emails`, `email_attachments`, `events`, `vendor_invoice_inbox` for `realm` rows that disagree with `_MAILBOX_REALM[account]` — should be 0 if V64a is working, but verify.

**Acceptance**:
- `docker compose up -d --no-deps google-fetch` rebuilds clean.
- `curl http://google-fetch:8011/poll-and-emit?newer_than=10m` writes new rows. `SELECT realm FROM emails WHERE created_at > now() - interval '10 min'` shows realm matches the `_MAILBOX_REALM[account]` lookup for every row.
- `bash scripts/u53-r5-realm-backfill.sh --audit-only` returns 0 mismatches.

---

### T2 — V67 realm immutability (~30 min)

**Realm**: owner (migration; trigger applies cross-realm).

**Build**:
- `postgres/migrations/V67__realm_immutability.sql`:
  - Define `home_ai.realm_override(p_table TEXT, p_id BIGINT, p_new_realm TEXT, p_reason TEXT)` SECURITY DEFINER function that:
    1. Requires `current_setting('app.current_realm', true) = 'owner'` — raises EXCEPTION otherwise.
    2. Validates `p_new_realm IN ('owner','work','family','shared')`.
    3. Sets a session variable `app.realm_override_active = '1'`.
    4. Executes `EXECUTE format('UPDATE %I SET realm = $1 WHERE id = $2', p_table) USING p_new_realm, p_id`.
    5. Inserts an `audit_log` row with `action='realm_override'`, the table, id, old realm, new realm, reason, and `app.current_user`.
    6. Clears `app.realm_override_active`.
  - For each of `emails`, `email_attachments`, `events`, `documents`, `vendor_invoice_inbox`, `vendor_invoice_lines`, `bank_transactions`: create a BEFORE UPDATE trigger that raises EXCEPTION if `NEW.realm != OLD.realm AND current_setting('app.realm_override_active', true) IS DISTINCT FROM '1'`.
  - Comment block explains the rule: realm at insert is the source of truth; updates that mutate realm must go through `home_ai.realm_override()`.

**Acceptance**:
- `UPDATE emails SET realm='family' WHERE id=<a work row>;` raises `realm_immutable_without_override`.
- `SET LOCAL app.current_realm='owner'; SELECT home_ai.realm_override('emails', <id>, 'family', 'misdirected-invoice-2026-05-14');` succeeds; row updates; `audit_log` row visible.
- `SET LOCAL app.current_realm='work'; SELECT home_ai.realm_override('emails', <id>, 'work', 'test');` raises `realm_override_requires_owner`.

---

### T3 — U50 dashboard UI closeout (~30 min)

**Realm**: work (touches pub/cafe operational economics view).

**Why**: V60 added `labour_cost_pub` / `labour_cost_cafe` / `labour_cost_inn` / `labour_cost_shared` to `v_daily_unit_economics` (confirmed live: workforce_departments mapped pub=2, cafe=1, inn=1, shared=1). `/api/economics/overview` returns those columns via `SELECT *`. The unstaged `services/build-dashboard/static/economics.html` adds Pub £ / Cafe £ / Inn £ + per-site Labour % columns to the Tabulator. Ship it.

**Build**:
- Stage the unstaged `services/build-dashboard/static/economics.html` + `services/build-dashboard/static/index.html` (the latter adds the `/vehicles` link).
- Add a `cafe_labour_pct` derivation if it's not in the view (check; v_daily_unit_economics already has `pub_labour_pct` per the column list — verify cafe equivalent).
- Restart build-dashboard: `docker compose restart build-dashboard`.
- Manual smoke: open `/economics`, confirm Pub £ / Cafe £ / Inn £ columns render with non-NULL values for recent dates.

**Acceptance**:
- `curl 'http://localhost:8000/api/economics/overview?days=7' | jq '.rows[0] | {labour_cost_pub, labour_cost_cafe, labour_cost_inn}'` returns three numbers, not nulls.
- Sandwich Bar GP% line stops sharing labour with the pub.

---

### T4 — U50 sprint plan formally closed + STATE/debt sync (~20 min)

**Realm**: owner.

**Build**:
- Append a `## Closeout 2026-05-14` section to `.claude/sprints/U50-settle-the-books.md` summarising what landed (T1 cron'd, T2 V60 live with site mapping, T3 V61 + script live with 72% PDFs tagged, T4 stale-ack cron'd, T5 prompt examples added in main.py:1081). The plan stays untracked-in-git until U53's exit commit.
- Update `services/build-dashboard/data/tasks.yaml`: move U50 items from `hands_off` to a `done:` section with the shipping commit hash. Resolve the `subject-aware-vendor-rules` item explicitly (already a comment in the unstaged diff — make it real).
- Update `/home_ai/STATE.md`: append a §0.1 "U50 closeout + R5 in flight" block.

**Acceptance**:
- `grep -A2 "## Closeout" .claude/sprints/U50-settle-the-books.md` shows the new section.
- `services/build-dashboard/data/tasks.yaml` has no remaining U50 items in `hands_off`.

---

### T5 — Telegram pulse + sprint exit commit (~15 min)

**Realm**: owner.

**Build**:
- Telegram pulse via `telegram_outbox`:
  ```
  U53 shipped: R5 google-fetch realm-tagging (5 mailboxes mapped),
  V67 realm immutability with home_ai.realm_override chokepoint,
  U50 closeout (per-site labour UI shipped, 72% PDFs have due_date,
  bot_feedback applier crond, stale-ack crond). REALM_ENFORCE still 0.
  ```
- Single commit on a fresh branch `u53-realm-r5-u50-closeout`:
  - `git add postgres/migrations/V67__realm_immutability.sql services/google-fetch/main.py services/build-dashboard/static/economics.html services/build-dashboard/static/index.html services/build-dashboard/data/tasks.yaml scripts/u53-r5-realm-backfill.sh .claude/sprints/U50-settle-the-books.md .claude/sprints/U53-realm-r5-ingest-u50-closeout.md STATE.md`
  - Per [[feedback_homeai_pre_push_scan]] — entropy-scan staged tree.

**Acceptance**:
- Commit lands locally.
- Telegram message received.
- Push deferred to user.

## Sequence + acceptance

| # | Track                         | Effort | Depends on | Gate |
|---|-------------------------------|--------|------------|------|
| 1 | google-fetch realm tagging    | 45m    | —          | Audit-only backfill shows 0 mismatches |
| 2 | V67 immutability              | 30m    | T1         | Direct UPDATE raises; override path works |
| 3 | U50 dashboard UI              | 30m    | —          | Per-site labour numbers render in `/economics` |
| 4 | U50 closeout docs             | 20m    | T3         | tasks.yaml drained of U50 items |
| 5 | Telegram + commit             | 15m    | T1-T4      | Branch + commit |

**Total est**: ~2h 20m. T1 + T3 are independent; T2 depends on T1 (needs the explicit realm to compare in the immutability check). T4 / T5 sequential at the end.

## What this sprint does NOT do

- **R6 — Bot/AI scope** (Haiku/Sonnet call-site realm context): folded into U54.
- **R7 — Backup** (realm-scoped pg_dump): folded into U55.
- **R3 / R4 full** (Auth + REALM_ENFORCE=1 flip): in-person, blocked on tailscale-cert FQDN.
- **U51 Jo-input catchup**: vehicles V5C, Xero retry, Companies House key, HMRC sandbox — needs Jo at keyboard.
- **Orphan-unstaged: u29-xero-bootstrap XERO_SCOPES env, u29-daily-digest uncertain block, google-fetch attachment-idempotency comment** — these are correct fixes from prior sprints that never got their own commit. Punt to a small "U53-tail housekeeping" commit after the sprint lands.

## Abort criteria

Per discipline rule #9, abort and hand off to a fresh session if:
- T1: 4th attempt at the `_MAILBOX_REALM` wiring fails the backfill audit. (Probably means an unknown `account` value — investigate, don't iterate.)
- T2: the BEFORE UPDATE trigger blocks a legitimate UPDATE in any consumer (feedback applier, ack scripts). Restore V67, document the consumer, hand off — the trigger needs the override-flag escape hatch, not a workaround.
- T3: V60's per-site labour columns return all-NULLs for a recent date despite `workforce_departments.site` being populated. Means the view aggregation is broken — out of scope to debug in U53.

Reply `go` to start; this is a single contiguous autonomous run with a Telegram pulse at each track boundary.
