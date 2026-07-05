# U294 — Bank Line Categories Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Categorise the 21,332 NULL-category bank_transactions rows (96% of 22,213; £27M abs volume, 2019→2026) left honest-but-empty by the V293 bank_fee catch-all fix, with structural guards so a category can never again silently sum £2.3M of transfers into a cost tile.

**Architecture:** Four layers, cheapest first: (1) a category *registry* giving every category a `kind` (income/cost/transfer/financing/tax/neutral) that views aggregate by; (2) deterministic transfer pairing between our own 18 accounts; (3) an evidence-seeded narrative rule pack applied by the existing u58 engine (hardened); (4) an LLM tail pass over the residual *clusters* (not rows), threshold-gated into a review view. Counterparty resolution stays shadow (0 bank anchors exist — it cannot lead; a later sprint flips it).

**Tech Stack:** Postgres migrations (V294+), bash/SQL (u58 engine), Python + ollama qwen2.5:7b for the tail, ops-run.sh registry heartbeats.

## Global Constraints

- Postgres access: `docker exec -i homeai-postgres psql -U postgres -d homeai` and EVERY session starts `SET app.current_entity='all'; SET app.current_realm='owner';`
- Every data-mutating task: backup table `_backup_u294_<taskN>` of exactly the rows touched, BEFORE the update, plus a printed before/after cross-foot (rows + Σabs(amount)) whose delta must equal intent. Rollback SQL documented in the migration/commit.
- `bank_transactions` contains exact-duplicate rows: any *analytical* sum must dedup with `row_number() OVER (PARTITION BY bank_account_id, transaction_date, amount, description)` first. Categorisation UPDATEs may touch dups (same row → same category) — that is correct, only sums must dedup.
- Never trust `transaction_date` alone on account 15 (48885517) for pre-rebuild data; `balance` is the trustworthy column (bank-ledger-rebuild 2026-06-19).
- No new rules with an empty match predicate (the V293 root cause). Task 1 adds the constraint; nothing may bypass it.
- Categories are snake_case; every category used anywhere MUST have a `bank_category_registry` row (FK enforced from Task 1).
- Realm: entity 1–2 accounts = `work`, entity 3–4 = `personal`. Rules that are entity-specific set `entity_in`; realm column on rules follows the entity it targets, `owner`-written data keeps its existing row realm untouched.
- Commits: exact-path staging only (`git add <paths>`); end messages with the session trailer used in this repo (see recent `git log`).
- Sums quoted in reports: state them from a query run in that session (data-integrity discipline), never from this plan.

## Canonical taxonomy (locked here; Task 1 seeds it)

| category | kind | meaning |
|---|---|---|
| income_trading | income | card-settlement/takings credits (YouLend remits, Dojo, till banking) |
| income_rent | income | rent received (ARE/personal lets) |
| income_other | income | refunds in, misc credits, interest_credit stays its own row below |
| internal_transfer | transfer | between our OWN accounts (any entity), incl. card top-ups from own accounts |
| inter_entity_transfer | transfer | already exists — keep; between entities (ATR↔ARE↔personal) |
| card_repayment | transfer | payments TO our credit cards (CoT DD, RBS Mastercard pymts) — card spend itself lives in card_statements |
| financing_advance | financing | loan money in (YouLend advance legs, new borrowings) |
| financing_repayment | financing | loan principal+interest out (YouLend sweep, loan DDs) |
| mortgage_payment | financing | Principality + other mortgage DDs |
| property_purchase | cost | completion-scale property outflows |
| supplier_payment | cost | trade suppliers paid by bank (not card) |
| wages | cost | payroll FPs/BACS |
| tax_hmrc | tax | VAT, PAYE/NI, CT |
| professional_fees | cost | solicitors, accountants, brokers |
| bank_fee | cost | exists (150 rows) — keep, guarded by V293 pattern |
| interest_charged | cost | exists — keep |
| interest_credit | income | exists — keep |
| refund | income | exists — keep |
| personal_spend | neutral | personal-account outflows that are none of the above |
| needs_review | neutral | LLM/human could not decide — surfaced, never summed |

---

### Task 1: V294 migration — category registry, kind mapping, rule lint

**Files:**
- Create: `postgres/migrations/V294__bank_category_registry.sql`

**Interfaces:**
- Produces: table `bank_category_registry(category text PK, kind text CHECK (kind IN ('income','cost','transfer','financing','tax','neutral')), description text)`; FK `bank_transactions.category → bank_category_registry(category)` (NOT VALID until Task 6); CHECK constraint `bank_transaction_rules_has_predicate` on `bank_transaction_rules`. Every later task inserts only categories present in the registry.

- [ ] **Step 1: Write the migration**

```sql
-- V294 (2026-07-05, U294) — bank category registry + structural guards.
-- The V293 lesson made structural: every category carries a kind, views
-- aggregate by kind, and a rule can never exist without a match predicate.
SET app.current_entity='all'; SET app.current_realm='owner';

CREATE TABLE IF NOT EXISTS bank_category_registry (
  category    text PRIMARY KEY,
  kind        text NOT NULL CHECK (kind IN ('income','cost','transfer','financing','tax','neutral')),
  description text NOT NULL
);

INSERT INTO bank_category_registry (category, kind, description) VALUES
 ('income_trading','income','card-settlement/takings credits (YouLend remits, Dojo, till banking)'),
 ('income_rent','income','rent received'),
 ('income_other','income','misc credits/refunds in'),
 ('internal_transfer','transfer','between our own accounts, any entity'),
 ('inter_entity_transfer','transfer','between entities (pre-existing category)'),
 ('card_repayment','transfer','payments to our own credit cards'),
 ('financing_advance','financing','loan money in'),
 ('financing_repayment','financing','loan principal+interest out'),
 ('mortgage_payment','financing','Principality + other mortgage DDs'),
 ('property_purchase','cost','completion-scale property outflows'),
 ('supplier_payment','cost','trade suppliers paid by bank'),
 ('wages','cost','payroll FPs/BACS'),
 ('tax_hmrc','tax','VAT, PAYE/NI, CT'),
 ('professional_fees','cost','solicitors, accountants, brokers'),
 ('bank_fee','cost','genuine bank charges (V293-guarded)'),
 ('interest_charged','cost','debit interest'),
 ('interest_credit','income','credit interest'),
 ('refund','income','refunds (pre-existing category)'),
 ('personal_spend','neutral','personal-account outflow, none of the above'),
 ('needs_review','neutral','undecided — surfaced, never summed')
ON CONFLICT (category) DO NOTHING;

-- FK: added NOT VALID so historical rows don't block; Task 6 validates.
ALTER TABLE bank_transactions
  ADD CONSTRAINT bank_transactions_category_fk
  FOREIGN KEY (category) REFERENCES bank_category_registry(category) NOT VALID;

-- Rule lint: the V293 root cause (predicate-less rule) becomes impossible.
ALTER TABLE bank_transaction_rules
  ADD CONSTRAINT bank_transaction_rules_has_predicate CHECK (
    coalesce(description_re,'') <> ''
    OR (amount_op IS NOT NULL AND amount_value IS NOT NULL)
  );
```

- [ ] **Step 2: Apply and verify**

Run: `docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 -f - < postgres/migrations/V294__bank_category_registry.sql`
Expected: CREATE TABLE / INSERT 0 20 / two ALTER TABLE. If the CHECK fails to add, an existing predicate-less rule still exists — list it (`SELECT id,name FROM bank_transaction_rules WHERE coalesce(description_re,'')='' AND (amount_op IS NULL OR amount_value IS NULL);`), review it against V293, delete or fix it, re-apply.

- [ ] **Step 3: Verify existing categories are all registered**

Run: `docker exec -i homeai-postgres psql -U postgres -d homeai -tA -c "SET app.current_entity='all'; SELECT DISTINCT category FROM bank_transactions WHERE category IS NOT NULL EXCEPT SELECT category FROM bank_category_registry;"`
Expected: zero rows. If any appear, add registry rows for them (pick kind honestly) before continuing.

- [ ] **Step 4: Commit**

```bash
cd /home_ai && git add postgres/migrations/V294__bank_category_registry.sql
git commit -m "feat(finance): V294 bank category registry + kind mapping + rule lint (U294 T1)"
```

---

### Task 2: Transfer pairing — internal_transfer + card_repayment

**Files:**
- Create: `scripts/u294-transfer-pairing.sql` (one-shot, re-runnable)

**Interfaces:**
- Consumes: `bank_category_registry` from Task 1.
- Produces: NULL-category rows whose counterpart leg is another own account become `internal_transfer` (or `card_repayment` when the credit side is a card account 11–14,16–19); `category_source='u294:pairing'`.

- [ ] **Step 1: Measure the candidate population (record the number)**

```sql
SET app.current_entity='all'; SET app.current_realm='owner';
-- own-account references appearing in descriptions (accounts table holds the numbers)
SELECT count(*), sum(abs(amount))::bigint FROM bank_transactions bt
WHERE bt.category IS NULL
  AND (bt.description ~* 'TO A/C|FROM A/C|VIA MOBILE|MOBILE/ONLINE'
       OR EXISTS (SELECT 1 FROM bank_accounts a
                   WHERE a.id <> bt.bank_account_id
                     AND length(coalesce(a.account_number,'')) >= 8
                     AND bt.description LIKE '%'||a.account_number||'%'));
```

- [ ] **Step 2: Write the pairing script**

```sql
-- scripts/u294-transfer-pairing.sql — deterministic own-account transfer detection.
-- Two independent signals, applied in order; idempotent (category IS NULL guard).
\set ON_ERROR_STOP on
SELECT set_config('app.current_entity','all',false);
SELECT set_config('app.current_realm','owner',false);

BEGIN;
CREATE TABLE IF NOT EXISTS _backup_u294_task2 AS
  SELECT id, category, category_source FROM bank_transactions WHERE false;

-- Signal A: description names one of OUR account numbers -> transfer, and
-- card accounts on the other side -> card_repayment.
WITH tagged AS (
  SELECT bt.id,
         CASE WHEN a_other.account_type ILIKE '%card%'
               OR a_other.account_name ILIKE '%mastercard%'
               OR a_other.account_name ILIKE '%cap on tap%'
              THEN 'card_repayment' ELSE 'internal_transfer' END AS newcat
    FROM bank_transactions bt
    JOIN bank_accounts a_other
      ON a_other.id <> bt.bank_account_id
     AND length(coalesce(a_other.account_number,'')) >= 8
     AND bt.description LIKE '%'||a_other.account_number||'%'
   WHERE bt.category IS NULL
), bk AS (
  INSERT INTO _backup_u294_task2
  SELECT b.id, b.category, b.category_source FROM bank_transactions b JOIN tagged t ON t.id=b.id
  RETURNING 1
)
UPDATE bank_transactions bt
   SET category=t.newcat, category_confidence=0.95, category_source='u294:pairing:acctno'
  FROM tagged t WHERE bt.id=t.id;

-- Signal B: opposite-amount pair between two own accounts within 3 days,
-- both still NULL, description carries a transfer phrase on at least one leg.
WITH pairs AS (
  SELECT o.id AS out_id, i.id AS in_id
    FROM bank_transactions o
    JOIN bank_transactions i
      ON i.amount = -o.amount AND o.amount < 0
     AND i.bank_account_id <> o.bank_account_id
     AND i.transaction_date BETWEEN o.transaction_date AND o.transaction_date + 3
   WHERE o.category IS NULL AND i.category IS NULL
     AND (o.description ~* 'TO A/C|VIA MOBILE|MOBILE/ONLINE|ONLINE TRANSACTION'
          OR i.description ~* 'FROM A/C|VIA MOBILE|MOBILE/ONLINE|AUTOMATED CREDIT')
), ids AS (
  SELECT out_id AS id FROM pairs UNION SELECT in_id FROM pairs
), bk AS (
  INSERT INTO _backup_u294_task2
  SELECT b.id, b.category, b.category_source FROM bank_transactions b JOIN ids ON ids.id=b.id
  RETURNING 1
)
UPDATE bank_transactions bt
   SET category='internal_transfer', category_confidence=0.85, category_source='u294:pairing:legmatch'
  FROM ids WHERE bt.id=ids.id;

-- Cross-foot: transfers must roughly net to zero on deduped legmatch pairs.
SELECT category_source, count(*), sum(amount)::numeric(14,2) AS net
  FROM (SELECT *, row_number() OVER (PARTITION BY bank_account_id,transaction_date,amount,description ORDER BY id) rn
          FROM bank_transactions WHERE category_source LIKE 'u294:pairing%') d
 WHERE rn=1 GROUP BY 1;
COMMIT;
```

- [ ] **Step 3: Run it; check the cross-foot**

Run: `docker exec -i homeai-postgres psql -U postgres -d homeai -f - < scripts/u294-transfer-pairing.sql`
Expected: `u294:pairing:legmatch` net ≈ 0 (tolerance: |net| < 2% of its Σabs). `acctno` net will NOT be zero (one-sided references) — that is fine. If legmatch net is large, inspect 10 sample pairs before proceeding; a same-amount coincidence join is the failure mode.

- [ ] **Step 4: Commit**

```bash
cd /home_ai && git add scripts/u294-transfer-pairing.sql
git commit -m "feat(finance): U294 T2 — own-account transfer pairing (acct-no + leg-match signals)"
```

---

### Task 3: Narrative rule pack — evidence-seeded, no catch-alls

**Files:**
- Create: `postgres/migrations/V295__u294_bank_narrative_rules.sql`

**Interfaces:**
- Consumes: registry categories (Task 1). Rules obey the Task-1 CHECK.
- Produces: ~25 seeded `bank_transaction_rules` rows applied via existing `scripts/u58-bank-tx-categorise.sh`.

Evidence base (top uncategorised tokens by £ volume, measured 2026-07-05): `AUTOMATED CREDIT PAYMENT` £1.88M, own-transfer phrases ~£4.7M (Task 2 takes those), `YOULEND` £1.04M, `PAYMENT MADE (DIRECT DEB` £0.68M, `CAPITAL ON TAP DD` £0.66M, `PRINCIPALITY BS` £0.29M, `HMRC` £0.29M, `AUTOMATED CREDIT FDEL FA` £0.29M/526 rows, `ATLANTIC CONSTRUCT` £0.22M.

- [ ] **Step 1: Seed the known-counterparty rules**

```sql
-- V295 (2026-07-05, U294 T3) — narrative rule pack. Every rule has a real
-- regex (V294 CHECK enforces). Confidence: 0.9 counterparty-anchored,
-- 0.8 pattern-anchored. priority 10-block leaves room above existing rules.
SET app.current_entity='all'; SET app.current_realm='owner';
INSERT INTO bank_transaction_rules (priority,name,description_re,amount_op,amount_value,entity_in,category,confidence,notes,realm) VALUES
 (110,'YouLend remit (card takings)','YOULEND|YL LIMITED','>',0,'{1}','income_trading',0.90,'Dojo takings via YouLend MCA, net of loan sweep — see feedback_dojo_youlend_financing','work'),
 (111,'YouLend sweep out','YOULEND|YL LIMITED','<',0,'{1}','financing_repayment',0.90,'MCA repayment legs','work'),
 (112,'Capital on Tap repayment DD','CAPITAL ON TAP|CAPITALONTAP','<',0,'{1}','card_repayment',0.90,'card acct 16 tracked in card_statements','work'),
 (113,'Principality mortgage','PRINCIPALITY','<',0,NULL,'mortgage_payment',0.90,'295905-02 cross-collateral; both entities pay','owner'),
 (114,'HMRC','HMRC|H\.?M\.? REVENUE','<',0,NULL,'tax_hmrc',0.90,'VAT/PAYE/CT out','owner'),
 (115,'HMRC refund in','HMRC|H\.?M\.? REVENUE','>',0,NULL,'income_other',0.85,'tax repayments','owner'),
 (116,'Atlantic Construct payments','ATLANTIC CONSTRUCT','<',0,NULL,'supplier_payment',0.85,'separate payee, NOT inter-entity — ATR recon 2026-06','work'),
 (117,'Dojo settlement credits','DOJO|PAYMENTSENSE','>',0,'{1}','income_trading',0.90,'pre-YouLend era settlements','work'),
 (118,'Interest charged (residual)','DEBIT INTEREST|INTEREST CHARGED','<',0,NULL,'interest_charged',0.90,'','owner'),
 (119,'Wages FP runs','WAGES|SALARY|PAYROLL','<',0,'{1,2}','wages',0.85,'','work');
-- Rules for AUTOMATED CREDIT PAYMENT (£1.88M), FDEL FA (£0.29M/526 rows) and
-- 'PAYMENT MADE (DIRECT DEB' are NOT seeded here: Step 2 identifies them first.
```

- [ ] **Step 2: Identify the three big unattributed patterns before ruling them**

For each of `AUTOMATED CREDIT PAYMENT`, `AUTOMATED CREDIT FDEL FA`, `PAYMENT MADE (DIRECT DEB`, pull 15 sample rows (full description, amount, account, date spread):
```sql
SELECT bank_account_id, transaction_date, amount, description
  FROM bank_transactions WHERE category IS NULL AND description ~* 'FDEL FA'
 ORDER BY transaction_date DESC LIMIT 15;
```
Decide each against the taxonomy (e.g. if FDEL turns out to be a card-settlement processor → income_trading on the credit side). Add one rule per resolved pattern to V295 with a comment recording the evidence. If a pattern is genuinely ambiguous, leave it for the Task-5 LLM tail — do NOT write a loose rule.

- [ ] **Step 3: Apply migration, run u58, measure**

```bash
docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 -f - < postgres/migrations/V295__u294_bank_narrative_rules.sql
bash /home_ai/scripts/u58-bank-tx-categorise.sh
```
Then re-run the coverage query (Task 6 Step 1 SQL). Expected: NULL-row *volume* share drops materially; every new category value already exists in the registry (FK would reject otherwise). Record before/after counts in the commit message.

- [ ] **Step 4: Spot-check 10 rows per new rule**

`SELECT ... WHERE category_source='rule:YouLend remit (card takings)' ORDER BY random() LIMIT 10;` — read descriptions, confirm no false positives. A rule with any false positive gets tightened and its rows reset to NULL (`UPDATE ... SET category=NULL, category_source=NULL WHERE category_source='rule:<name>'`) before re-run.

- [ ] **Step 5: Commit**

```bash
cd /home_ai && git add postgres/migrations/V295__u294_bank_narrative_rules.sql
git commit -m "feat(finance): U294 T3 — narrative rule pack (YouLend/CoT/Principality/HMRC/+identified patterns)"
```

---

### Task 4: u58 hardening — heartbeat, registry, coverage report

**Files:**
- Modify: `scripts/u58-bank-tx-categorise.sh` (wrap + report; do not rewrite the SQL engine)

**Interfaces:**
- Produces: u58 registered in `ops.pipeline_registry` as `bank_tx_categorise` with freshness SQL `SELECT max(created_at)... ` replaced by a run-based check (`SELECT max(finished_at) FROM ops.pipeline_runs WHERE name='bank_tx_categorise' AND status='ok'`), SLA 26h; cron line via `ops-run.sh`; per-run stdout ends with `OPS_ROWS=<n>` and a category-kind coverage line.

- [ ] **Step 1: Append to the end of u58-bank-tx-categorise.sh**

```bash
# U294 T4: per-run coverage heartbeat (kind-level, deduped)
docker exec -i homeai-postgres psql -U postgres -d homeai -tA <<'SQL'
SET app.current_entity='all'; SET app.current_realm='owner';
SELECT 'coverage: '||string_agg(kind||'='||n, ' ' ORDER BY kind)
FROM (SELECT coalesce(r.kind,'uncategorised') kind, count(*) n
        FROM (SELECT *, row_number() OVER (PARTITION BY bank_account_id,transaction_date,amount,description ORDER BY id) rn
                FROM bank_transactions) d
        LEFT JOIN bank_category_registry r ON r.category=d.category
       WHERE d.rn=1 GROUP BY 1) t;
SQL
```
Also ensure the script's final line prints `OPS_ROWS=<rows updated this run>` (the engine's DO block already counts `total_applied` — RAISE NOTICE it and grep it in the wrapper).

- [ ] **Step 2: Register + schedule**

```sql
INSERT INTO ops.pipeline_registry(name,kind,script_path,schedule_cron,target_rel,freshness_sql,freshness_sla_hours,notes)
VALUES('bank_tx_categorise','maintenance','scripts/u58-bank-tx-categorise.sh','35 5 * * *','bank_transactions',
       'SELECT max(finished_at) FROM ops.pipeline_runs WHERE name=''bank_tx_categorise'' AND status=''ok''',26,'U294 rule engine, daily')
ON CONFLICT(name) DO UPDATE SET schedule_cron=EXCLUDED.schedule_cron, freshness_sql=EXCLUDED.freshness_sql, notes=EXCLUDED.notes;
```
Add the cron line to `scripts/gen-canonical-crontab.py`'s source-of-truth (follow how other entries are defined there — do NOT hand-edit the live crontab) and run `scripts/install-crontab.sh`.

- [ ] **Step 3: Run once through the wrapper, verify heartbeat**

Run: `bash scripts/ops-run.sh bank_tx_categorise -- bash scripts/u58-bank-tx-categorise.sh`
Expected: coverage line prints, `[ops-run] ... rc=0` line prints, and `SELECT status FROM ops.pipeline_runs WHERE name='bank_tx_categorise' ORDER BY started_at DESC LIMIT 1;` = `ok`.

- [ ] **Step 4: Commit**

```bash
cd /home_ai && git add scripts/u58-bank-tx-categorise.sh scripts/gen-canonical-crontab.py scripts/crontab.canonical.txt
git commit -m "feat(ops): U294 T4 — u58 categoriser heartbeat + registry + daily cron"
```

---

### Task 5: LLM tail pass — clusters, not rows

**Files:**
- Create: `scripts/u294-bank-llm-tail.py`

**Interfaces:**
- Consumes: residual `category IS NULL` rows after Tasks 2–3; registry category list (prompt is built FROM the registry so the model can only pick real categories).
- Produces: rows updated with `category_source='llm:qwen7b:u294v1'`, `category_confidence=0.70`; undecided clusters → `needs_review` with `category_confidence=0`; cluster decisions logged to stdout for the run log.

Design rules:
- Cluster key: `upper(regexp_replace(substring(description for 24),'[0-9]','','g')) || ':' || sign(amount) || ':' || entity_id`. Classify each cluster ONCE with 5 sample descriptions + amount stats; apply to all members. 21k rows collapse to a few hundred clusters.
- Only clusters with Σabs(amount) ≥ £250 OR n ≥ 10 go to the model; smaller ones → `needs_review` directly (not worth tokens).
- Model: `qwen2.5:7b` via `http://127.0.0.1:11434/api/generate`, `temperature 0`, strict JSON `{"category": "<registry value>", "reason": "<one line>"}`; a response not exactly matching a registry category (excluding the transfer categories, which ONLY Tasks 2–3 may assign — the model must never invent a transfer) → `needs_review`.
- Backup table `_backup_u294_task5` (id, old category/source) before applying, same pattern as Task 2.

- [ ] **Step 1: Write the script** (structure below; follow u281-vision-ocr-drain.py for the psql/ollama helpers — same idioms, same container calls)

```python
#!/usr/bin/env python3
"""u294-bank-llm-tail.py — classify residual uncategorised bank clusters.
Reads registry categories live; model may only answer with one of them
(minus transfer kinds, which deterministic layers own). Idempotent:
only touches category IS NULL rows."""
# helpers psql()/psql_exec() copied from u281-vision-ocr-drain.py (same repo idiom)

ALLOWED_SQL = """SELECT category FROM bank_category_registry
                 WHERE kind NOT IN ('transfer')"""
CLUSTER_SQL = """
  SELECT upper(regexp_replace(substring(description for 24),'[0-9]','','g'))
         ||':'||sign(amount)::int||':'||entity_id AS ckey,
         count(*) n, sum(abs(amount))::numeric(14,2) vol,
         (array_agg(description ORDER BY abs(amount) DESC))[1:5] samples,
         min(amount) min_amt, max(amount) max_amt, entity_id
    FROM bank_transactions
   WHERE category IS NULL
   GROUP BY 1, entity_id
  HAVING sum(abs(amount)) >= 250 OR count(*) >= 10
   ORDER BY vol DESC"""

PROMPT_TMPL = (
  "You are categorising UK bank-statement lines for a pub/property owner.\n"
  "Allowed categories (answer with EXACTLY one): {cats}\n"
  "If genuinely unsure answer needs_review. NEVER guess a transfer.\n"
  "Lines (same pattern, {n} rows, GBP total {vol}):\n{samples}\n"
  'Return ONLY JSON: {{"category": "...", "reason": "..."}}'
)
# main(): fetch allowed set; for each cluster: build prompt (use .replace for
# the samples slot — r2-bench str.format/JSON-brace lesson), call ollama
# temperature 0 num_predict 120, validate category in allowed set else
# 'needs_review'; backup member ids to _backup_u294_task5; single UPDATE per
# cluster: SET category=%s, category_confidence=0.70 (0 for needs_review),
# category_source='llm:qwen7b:u294v1' WHERE category IS NULL AND <cluster key
# expression> = ckey; print "CLUSTER <ckey> n=<n> vol=<vol> -> <category>".
# End: print OPS_ROWS=<total updated>.
```
The implementer writes the full ~150-line script; the psql/ollama call sites, the two SQL blocks, the prompt, and the validation rule above are binding. Test first on `--limit 5` clusters (add that flag) and hand-check the 5 decisions before the full run.

- [ ] **Step 2: Dry-run 5 clusters, review, then full run**

Run: `python3 scripts/u294-bank-llm-tail.py --limit 5` → read the 5 CLUSTER lines, verify sane. Then full run (GPU note: qwen2.5:7b is the always-warm hot model; a few hundred generate calls ≈ minutes, no eviction risk).
Expected: every cluster line shows a registry category or needs_review; `SELECT count(*) FROM bank_transactions WHERE category IS NULL;` afterwards ≈ 0 (everything is categorised or needs_review).

- [ ] **Step 3: Commit**

```bash
cd /home_ai && git add scripts/u294-bank-llm-tail.py
git commit -m "feat(finance): U294 T5 — LLM tail classifier over residual clusters (registry-constrained)"
```

---

### Task 6: Acceptance — cross-foot suite, FK validation, consumer audit

**Files:**
- Create: `scripts/u294-acceptance.sql`
- Modify: none expected in views unless Step 3 finds a consumer assuming old semantics

- [ ] **Step 1: Coverage + kind cross-foot (the sprint's acceptance numbers)**

```sql
SET app.current_entity='all'; SET app.current_realm='owner';
-- (a) coverage by rows and by £ volume, deduped
WITH d AS (SELECT *, row_number() OVER (PARTITION BY bank_account_id,transaction_date,amount,description ORDER BY id) rn
             FROM bank_transactions)
SELECT coalesce(r.kind,'uncategorised') kind, count(*) rows,
       sum(abs(amount))::bigint vol,
       round(100.0*sum(abs(amount))/sum(sum(abs(amount))) OVER (),1) AS vol_pct
  FROM d LEFT JOIN bank_category_registry r ON r.category=d.category
 WHERE d.rn=1 GROUP BY 1 ORDER BY vol DESC;
-- (b) per-account 2026 monthly: categorised movement must equal balance-implied
-- movement within £1 for accounts with clean balance chains (3,5,15)
-- (c) transfer kind nets to ~0 across all accounts on legmatch pairs (Task 2 check re-run)
```
**Acceptance bars:** `uncategorised` (true NULL) = 0 rows; `needs_review` ≤ 15% of deduped £ volume; transfer legmatch |net| < 2% of its Σabs; (b) holds within £1/month for the three clean accounts.

- [ ] **Step 2: Validate the FK**

Run: `docker exec -i homeai-postgres psql -U postgres -d homeai -c "ALTER TABLE bank_transactions VALIDATE CONSTRAINT bank_transactions_category_fk;"`
Expected: succeeds. Failure = a category value outside the registry snuck in; find and fix it, never widen the registry casually.

- [ ] **Step 3: Consumer audit (13 views + /finance)**

For each view in: v_finance_monthly_summary, v_finance_recent_unified, v_inter_entity_owings, v_account_balances_now, v_finance_kpis, v_rental_income, v_uncategorised_summary, v_bank_category_month_summary, v_bank_recurring_charges, v_bank_interest_cost_summary, v_realm_audit_violations, v_card_fees_interest_by_month, v_account_transfers_open — read the definition (`\d+ <view>`); flag any that (a) hardcodes a category list that should now be kind-driven, or (b) sums income+cost+transfer together. Fix ONLY concrete misstatements (scope-fence: flag cosmetic modernisation, don't do it). Re-load `/finance` in build-dashboard and eyeball: "Fees paid (12m)" small and real; no tile jumped implausibly. Screenshot-note the before/after of any tile that changed and why it is more correct.

- [ ] **Step 4: Docs + close-out commit**

```bash
cd /home_ai && bash scripts/u89-gen-view-deps.sh && bash scripts/u89-gen-schema-doc.sh
git add scripts/u294-acceptance.sql docs/views.md docs/schema.md
git commit -m "feat(finance): U294 T6 — acceptance cross-foot suite green; FK validated; consumers audited"
```
Append the U294 summary line to MASTER.md per repo convention (separate commit fine).

---

## Explicitly OUT of scope (do not drift into these)
- Counterparty resolver bank flip (0 anchors; separate sprint after invoice-side provenance holds — memory `project_counterparty_resolver`).
- De-duplicating the physical duplicate rows in bank_transactions (analytical dedup only; physical fix is its own risky sprint).
- Dojo account 20 rebuild (deferred since 2026-06-19).
- Review UI for `needs_review` rows (F2 candidate; v_uncategorised_summary + /app/ops cover visibility for now).
- Re-deriving pre-2025 account-15 dates (statement-anchored; rebuilt ledger is canonical).

## Self-Review (done at write time)
- Spec coverage: V293's follow-up (categorise ~21k rows) → Tasks 2/3/5; "never again" structural ask → Task 1 registry+lint; consumers → Task 6. No gaps found.
- Placeholder scan: Task 5 delegates the script body but binds SQL, prompt, validation, idioms, and a reference implementation to copy helpers from — the one intentional delegation; all other steps carry full code.
- Type consistency: category values in Tasks 2/3/5 all appear in Task 1's registry seed; source tags all follow `u294:*`/`rule:*`/`llm:*` convention checked in Task 6.
