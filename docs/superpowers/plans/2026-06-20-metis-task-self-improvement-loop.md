# Metis — Task Self-Improvement Loop, Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the reusable Metis improvement loop (OBSERVE→DETECT→PROPOSE→REVIEW→MEASURE) running nightly beside the invoice-categorisation task, producing human-gated proposals to a Telegram digest — in shadow mode (nothing auto-applies until proven).

**Architecture:** A separate, async, nightly companion to the live `u-invoice-categorise-sweep` (which is untouched). Deterministic SQL detectors emit candidate `vendor_category_rules` changes into a `cognition.proposals` queue; proposals are deduped against a rejection memory and dry-run against a frozen `cognition.benchmark_labels` set; approved ones are applied reversibly and measured against the next night's observation, auto-raising corrective proposals on regression.

**Tech Stack:** PostgreSQL 16 (new `cognition.*` tables, plpgsql detector functions, RLS), bash cron scripts (`scripts/metis-*.sh`, `scripts/metis/`), `docker exec` into `homeai-postgres`, Vault for the DB password, existing critical-listener/Telegram path for the digest.

## Global Constraints

- **HARD FILE BOUNDARY (concurrent work):** Do NOT create, edit, or `git add` any of: `scripts/invoice-line-extract.py`, `scripts/u-invoice-line-sweep.sh`, `scripts/u-invoice-categorise-sweep.sh`, `scripts/u-invoice-pdf-date-sweep.sh`, `scripts/invoice-pdf-date-extract.py`, `scripts/wire-invoice-pipeline-vision-gemma4.py`, `services/build-dashboard/main.py`, `services/build-dashboard/static/*`. A parallel session owns these. Metis reads their DB outputs only. All new Metis code lives in NEW files (`scripts/metis-*.sh`, `scripts/metis/`, `postgres/migrations/`, `tests/metis/`).
- **No LLM in detection or apply.** Detectors are deterministic SQL. LLM output (if ever used) is advisory, labelled `category_source='llm_suggested'`, and never auto-approved. This plan uses NO LLM at all.
- **Nothing auto-applies in this plan.** Auto-approve stays OFF (shadow mode) until Task 12. Apply (Task 9) only acts on proposals a human set to `status='approved'`.
- **Realm in every table.** New tables carry a `realm` column + `entity_isolation` (where entity-scoped) and `realm_isolation` RLS policies + the standard GUC pattern. Reference: `postgres/migrations/V35__manager_notes.sql` and the `counterparty_anchor` policy block.
- **Idempotency.** Every script is safe to re-run: proposals use `INSERT … ON CONFLICT (task_id,detector,entity_ref,action_kind) DO UPDATE`; never `ON CONFLICT` on the `events` table (use `WHERE NOT EXISTS`) — but Metis does not write `events`.
- **DB access idiom** (copy verbatim into `scripts/metis/common.sh`, Task 2): get Vault token from the `homeai-google-fetch` container env, read `secret/postgres` password, then `docker exec -i -e PGPASSWORD=… homeai-postgres psql -U postgres -d homeai`.
- **Migration number:** this plan uses `V268`. Before applying, verify it's still free: `ls postgres/migrations/ | sort -V | tail -1` should be `V267…`. If a higher number exists (concurrent work), rename to the next free number.
- **task_id for the pilot:** the literal string `invoice.categorise`.

---

### Task 1: Migration — `cognition` loop tables + detector functions + RLS

**Files:**
- Create: `postgres/migrations/V268__metis_cognition_loop.sql`
- Test: `tests/metis/test_01_schema.sql`

**Interfaces:**
- Produces tables: `cognition.task_runs`, `cognition.proposals`, `cognition.proposal_rejections`, `cognition.benchmark_labels`.
- Produces functions (all `SECURITY DEFINER`, schema `cognition`): `fn_detect_categorise_gaps()`, `fn_detect_categorise_contradictions()`, `fn_detect_categorise_corrections()`, `fn_detect_categorise_overbroad(p_dead_days int)` — each returns `SETOF cognition.detection` (a composite type defined here).
- Produces view: `cognition.v_proposal_queue` (pending proposals ranked by `impact_gbp`).

- [ ] **Step 1: Write the failing test**

```sql
-- tests/metis/test_01_schema.sql  — run inside homeai-postgres; asserts and ROLLBACKs
\set ON_ERROR_STOP on
BEGIN;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM information_schema.tables
          WHERE table_schema='cognition'
            AND table_name IN ('task_runs','proposals','proposal_rejections','benchmark_labels')) = 4,
         'expected 4 cognition loop tables';
  ASSERT (SELECT count(*) FROM pg_policies
          WHERE schemaname='cognition' AND tablename='proposals' AND policyname='realm_isolation') = 1,
         'proposals must have realm_isolation policy';
  ASSERT to_regprocedure('cognition.fn_detect_categorise_gaps()') IS NOT NULL,
         'gap detector function must exist';
  ASSERT to_regclass('cognition.v_proposal_queue') IS NOT NULL,
         'proposal queue view must exist';
END $$;
ROLLBACK;
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
docker exec -i homeai-postgres psql -U postgres -d homeai -f - < tests/metis/test_01_schema.sql
```
Expected: FAIL — `ERROR: ... "expected 4 cognition loop tables"` (tables don't exist yet).

- [ ] **Step 3: Write the migration**

```sql
-- postgres/migrations/V268__metis_cognition_loop.sql
-- Metis self-improvement loop spine (design: docs/superpowers/specs/2026-06-20-metis-...).
-- Additive. Task-agnostic. Detectors are deterministic SQL (no LLM).
SET search_path = cognition, public;

CREATE TABLE IF NOT EXISTS cognition.task_runs (
  id          bigserial PRIMARY KEY,
  task_id     text NOT NULL,
  run_at      timestamptz NOT NULL DEFAULT now(),
  metrics     jsonb NOT NULL DEFAULT '{}'::jsonb,
  duration_ms integer,
  realm       text NOT NULL DEFAULT 'work'
              CHECK (realm IN ('owner','work','personal','shared'))
);
CREATE INDEX IF NOT EXISTS idx_task_runs_task_time ON cognition.task_runs(task_id, run_at DESC);

CREATE TABLE IF NOT EXISTS cognition.proposals (
  id                  bigserial PRIMARY KEY,
  task_id             text NOT NULL,
  detector            text NOT NULL,
  entity_ref          text NOT NULL,
  action_kind         text NOT NULL
                      CHECK (action_kind IN ('rule_insert','rule_narrow','rule_retire','noise_add','threshold_change')),
  action_payload      jsonb NOT NULL,
  revert_payload      jsonb,
  evidence            jsonb NOT NULL DEFAULT '{}'::jsonb,
  impact_gbp          numeric(12,2) NOT NULL DEFAULT 0,
  confidence          numeric(4,3),
  category_source     text NOT NULL DEFAULT 'deterministic'
                      CHECK (category_source IN ('deterministic','llm_suggested')),
  predicted_effect    jsonb,
  measured_effect     jsonb,
  status              text NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','approved','rejected','applied','reverted','auto_approved')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  decided_by          text,
  decided_at          timestamptz,
  applied_at          timestamptz,
  reverts_proposal_id bigint REFERENCES cognition.proposals(id),
  realm               text NOT NULL DEFAULT 'work'
                      CHECK (realm IN ('owner','work','personal','shared')),
  UNIQUE (task_id, detector, entity_ref, action_kind)
);
CREATE INDEX IF NOT EXISTS idx_proposals_pending ON cognition.proposals(task_id, status, impact_gbp DESC)
  WHERE status='pending';

CREATE TABLE IF NOT EXISTS cognition.proposal_rejections (
  id          bigserial PRIMARY KEY,
  task_id     text NOT NULL,
  signature   text NOT NULL,
  reason      text,
  rejected_by text NOT NULL DEFAULT 'jo',
  rejected_at timestamptz NOT NULL DEFAULT now(),
  realm       text NOT NULL DEFAULT 'work'
              CHECK (realm IN ('owner','work','personal','shared')),
  UNIQUE (task_id, signature)
);

CREATE TABLE IF NOT EXISTS cognition.benchmark_labels (
  task_id   text NOT NULL,
  key       text NOT NULL,
  expected  text NOT NULL,
  added_by  text NOT NULL DEFAULT 'jo',
  added_at  timestamptz NOT NULL DEFAULT now(),
  realm     text NOT NULL DEFAULT 'work'
            CHECK (realm IN ('owner','work','personal','shared')),
  PRIMARY KEY (task_id, key)
);

-- composite return type for detectors
DO $$ BEGIN
  CREATE TYPE cognition.detection AS (
    detector text, entity_ref text, action_kind text,
    action_payload jsonb, revert_payload jsonb, evidence jsonb,
    impact_gbp numeric, confidence numeric, category_source text,
    predicted_effect jsonb, realm text);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- RLS (default-deny realm pattern; copy of counterparty_anchor block)
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['task_runs','proposals','proposal_rejections','benchmark_labels'] LOOP
    EXECUTE format('ALTER TABLE cognition.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS realm_isolation ON cognition.%I', t);
    EXECUTE format($f$
      CREATE POLICY realm_isolation ON cognition.%I USING (
        CASE current_setting('app.current_realm', true)
          WHEN 'owner' THEN true
          WHEN 'work' THEN realm = ANY (ARRAY['work','shared'])
          WHEN 'personal' THEN realm = ANY (ARRAY['personal','shared'])
          ELSE (current_setting('app.current_realm', true) IS NULL
                OR current_setting('app.current_realm', true) = '')
        END)$f$, t);
    EXECUTE format('GRANT SELECT ON cognition.%I TO homeai_readonly', t);
  END LOOP;
END $$;

-- ── Detectors (deterministic). All return cognition.detection rows. ──
-- GAP: uncategorised invoices grouped by vendor_domain, ranked Σnet; suggested
-- category = majority category of that vendor's already-categorised siblings.
CREATE OR REPLACE FUNCTION cognition.fn_detect_categorise_gaps()
RETURNS SETOF cognition.detection LANGUAGE sql STABLE AS $$
  WITH uncat AS (
    SELECT vendor_domain,
           sum(COALESCE(net_amount, gross_amount, 0)) AS impact,
           count(*) AS n,
           array_agg(id ORDER BY id) AS sample_ids
    FROM vendor_invoice_inbox
    WHERE category_canonical IS NULL AND is_statement = false
      AND status NOT IN ('duplicate','ignored')
    GROUP BY vendor_domain
  ),
  majority AS (
    SELECT vendor_domain, vendor_category AS cat,
           row_number() OVER (PARTITION BY vendor_domain
                              ORDER BY count(*) DESC) AS rn
    FROM vendor_invoice_inbox
    WHERE vendor_category IS NOT NULL AND is_statement = false
    GROUP BY vendor_domain, vendor_category
  )
  SELECT 'gap', u.vendor_domain, 'rule_insert',
         jsonb_build_object('domain_pattern', u.vendor_domain, 'category', m.cat,
                            'site','shared','priority',100,'realm','work'),
         NULL::jsonb,
         jsonb_build_object('n_invoices', u.n, 'sample_ids', to_jsonb(u.sample_ids[1:5])),
         u.impact, 0.85, 'deterministic',
         jsonb_build_object('will_categorise', u.n, 'gbp', u.impact),
         'work'
  FROM uncat u JOIN majority m ON m.vendor_domain = u.vendor_domain AND m.rn = 1
  WHERE m.cat IS NOT NULL;
$$;

-- CONTRADICTION: one vendor_domain mapped to >=2 categories.
CREATE OR REPLACE FUNCTION cognition.fn_detect_categorise_contradictions()
RETURNS SETOF cognition.detection LANGUAGE sql STABLE AS $$
  WITH multi AS (
    SELECT vendor_domain,
           count(DISTINCT vendor_category) AS ncat,
           jsonb_agg(DISTINCT vendor_category) AS cats,
           sum(COALESCE(net_amount, gross_amount, 0)) AS impact
    FROM vendor_invoice_inbox
    WHERE vendor_category IS NOT NULL AND is_statement = false
      AND status NOT IN ('duplicate','ignored')
    GROUP BY vendor_domain
    HAVING count(DISTINCT vendor_category) >= 2
  )
  SELECT 'contradiction', vendor_domain, 'rule_narrow',
         jsonb_build_object('domain_pattern', vendor_domain, 'reason','multi-category; needs site split or rule fix'),
         NULL::jsonb,
         jsonb_build_object('categories', cats),
         impact, 0.70, 'deterministic',
         jsonb_build_object('categories_seen', cats),
         'work'
  FROM multi;
$$;

-- CORRECTION: a human re-categorisation in invoice_feedback that hasn't yet
-- produced a proposal. (ai_proposal lifecycle: pending = applied_at & rejected_at NULL.)
CREATE OR REPLACE FUNCTION cognition.fn_detect_categorise_corrections()
RETURNS SETOF cognition.detection LANGUAGE sql STABLE AS $$
  SELECT 'correction', v.vendor_domain, 'rule_insert',
         jsonb_build_object('domain_pattern', v.vendor_domain, 'from_feedback_id', f.id,
                            'feedback_text', f.feedback_text),
         NULL::jsonb,
         jsonb_build_object('invoice_id', f.invoice_id, 'feedback_id', f.id),
         COALESCE(v.net_amount, v.gross_amount, 0), 0.90, 'deterministic',
         jsonb_build_object('source','human_correction'),
         'work'
  FROM invoice_feedback f
  JOIN vendor_invoice_inbox v ON v.id = f.invoice_id
  WHERE f.applied_at IS NULL AND f.rejected_at IS NULL;
$$;

-- OVER-BROAD / DEAD: rules that never matched anything in p_dead_days days.
CREATE OR REPLACE FUNCTION cognition.fn_detect_categorise_overbroad(p_dead_days int DEFAULT 90)
RETURNS SETOF cognition.detection LANGUAGE sql STABLE AS $$
  SELECT 'dead', r.domain_pattern, 'rule_retire',
         jsonb_build_object('rule_id', r.id, 'domain_pattern', r.domain_pattern, 'category', r.category),
         jsonb_build_object('restore', to_jsonb(r)),         -- revert = re-insert the row
         jsonb_build_object('created_at', r.created_at),
         0, 0.60, 'deterministic',
         jsonb_build_object('dead_days', p_dead_days),
         r.realm
  FROM vendor_category_rules r
  WHERE NOT EXISTS (
    SELECT 1 FROM vendor_invoice_inbox v
    WHERE (v.vendor_domain ~* r.domain_pattern OR v.vendor_name ~* r.domain_pattern)
      AND v.ingested_at > now() - make_interval(days => p_dead_days)
  );
$$;

CREATE OR REPLACE VIEW cognition.v_proposal_queue AS
  SELECT id, task_id, detector, entity_ref, action_kind, impact_gbp, confidence,
         category_source, predicted_effect, evidence, created_at
  FROM cognition.proposals
  WHERE status = 'pending'
  ORDER BY impact_gbp DESC, created_at;
```

- [ ] **Step 4: Apply the migration**

Run:
```bash
docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 -f - < postgres/migrations/V268__metis_cognition_loop.sql
```
Expected: a series of `CREATE TABLE` / `CREATE FUNCTION` / `DO` with no error.

- [ ] **Step 5: Run test to verify it passes**

Run:
```bash
docker exec -i homeai-postgres psql -U postgres -d homeai -f - < tests/metis/test_01_schema.sql
```
Expected: `ROLLBACK` with no `ASSERT` failure (all four asserts pass).

- [ ] **Step 6: Commit**

```bash
git add postgres/migrations/V268__metis_cognition_loop.sql tests/metis/test_01_schema.sql
git commit -m "feat(metis): cognition loop tables + deterministic categorisation detectors (V268)"
```

---

### Task 2: Shared helper `scripts/metis/common.sh`

**Files:**
- Create: `scripts/metis/common.sh`
- Test: `tests/metis/test_02_common.sh`

**Interfaces:**
- Produces shell functions (sourced by every metis script): `metis_psql <args…>` (runs psql in the postgres container as superuser with the Vault password and `ON_ERROR_STOP`), `metis_psql_value "<sql>"` (returns a single scalar), and sets `METIS_GUC="SET app.current_entity='all'; SET app.current_realm='owner';"`.

- [ ] **Step 1: Write the failing test**

```bash
# tests/metis/test_02_common.sh
set -euo pipefail
source "$(dirname "$0")/../../scripts/metis/common.sh"
val=$(metis_psql_value "SELECT 1+1")
[ "$val" = "2" ] || { echo "FAIL: expected 2, got '$val'"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/metis/test_02_common.sh`
Expected: FAIL — `scripts/metis/common.sh: No such file or directory`.

- [ ] **Step 3: Write the helper**

```bash
# scripts/metis/common.sh — shared DB access for Metis scripts. Source, don't exec.
# Connects to homeai-postgres as superuser using the Vault-stored password.
_metis_pw() {
  local vt
  vt=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' \
       | grep '^VAULT_TOKEN=' | cut -d= -f2-)
  docker exec -e VAULT_TOKEN="$vt" homeai-vault vault kv get -field=password secret/postgres 2>/dev/null
}
METIS_GUC="SET app.current_entity='all'; SET app.current_realm='owner';"
metis_psql() {                      # passes args through to psql
  local pw; pw=$(_metis_pw)
  docker exec -i -e PGPASSWORD="$pw" homeai-postgres \
    psql -U postgres -d homeai -v ON_ERROR_STOP=1 "$@"
}
metis_psql_value() {                # one scalar
  local pw; pw=$(_metis_pw)
  docker exec -i -e PGPASSWORD="$pw" homeai-postgres \
    psql -U postgres -d homeai -tAc "$1"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/metis/test_02_common.sh`
Expected: `PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/metis/common.sh tests/metis/test_02_common.sh
git commit -m "feat(metis): shared psql helper (scripts/metis/common.sh)"
```

---

### Task 3: OBSERVE — `scripts/metis-observe.sh`

**Files:**
- Create: `scripts/metis-observe.sh`
- Test: `tests/metis/test_03_observe.sql`

**Interfaces:**
- Consumes: `metis_psql` from Task 2; reads `vendor_invoice_inbox`.
- Produces: one `cognition.task_runs` row (task_id `invoice.categorise`) per run with `metrics = {coverage_pct, population, categorised, uncategorised, mismatch_over_1k}`.

- [ ] **Step 1: Write the failing test**

```sql
-- tests/metis/test_03_observe.sql — asserts the metrics SQL the script will run.
\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE m jsonb;
BEGIN
  SELECT jsonb_build_object(
    'population', count(*) FILTER (WHERE is_statement=false AND status NOT IN ('duplicate','ignored')),
    'uncategorised', count(*) FILTER (WHERE category_canonical IS NULL AND is_statement=false AND status NOT IN ('duplicate','ignored'))
  ) INTO m FROM vendor_invoice_inbox;
  ASSERT (m->>'population')::int >= (m->>'uncategorised')::int, 'population must be >= uncategorised';
END $$;
ROLLBACK;
```

- [ ] **Step 2: Run test to verify it fails**

(The assert holds, but the script doesn't exist yet — this test guards the metrics invariant. Run it first to confirm the SQL is valid against the live table.)
Run: `docker exec -i homeai-postgres psql -U postgres -d homeai -f - < tests/metis/test_03_observe.sql`
Expected: PASS (validates the query) — proceed to write the script. *(If it errors, the column names are wrong; fix before continuing.)*

- [ ] **Step 3: Write the script**

```bash
# scripts/metis-observe.sh — OBSERVE stage for invoice.categorise.
# Writes one cognition.task_runs row. Cron: nightly, AFTER u-invoice-categorise-sweep.
set -uo pipefail
source "$(dirname "$0")/metis/common.sh"
metis_psql <<SQL
$METIS_GUC
INSERT INTO cognition.task_runs (task_id, metrics, realm)
SELECT 'invoice.categorise',
  jsonb_build_object(
    'population',     count(*) FILTER (WHERE is_statement=false AND status NOT IN ('duplicate','ignored')),
    'categorised',    count(*) FILTER (WHERE category_canonical IS NOT NULL AND is_statement=false AND status NOT IN ('duplicate','ignored')),
    'uncategorised',  count(*) FILTER (WHERE category_canonical IS NULL AND is_statement=false AND status NOT IN ('duplicate','ignored')),
    'coverage_pct',   round(100.0 * count(*) FILTER (WHERE category_canonical IS NOT NULL AND is_statement=false AND status NOT IN ('duplicate','ignored'))
                            / NULLIF(count(*) FILTER (WHERE is_statement=false AND status NOT IN ('duplicate','ignored')),0), 1),
    'mismatch_over_1k', 0
  ),
  'work'
FROM vendor_invoice_inbox;
SQL
echo "metis-observe: wrote task_run for invoice.categorise"
```

- [ ] **Step 4: Run the script and verify a row landed**

Run:
```bash
bash scripts/metis-observe.sh
docker exec -i homeai-postgres psql -U postgres -d homeai -tAc \
 "SET app.current_realm='owner'; SELECT metrics->>'coverage_pct' FROM cognition.task_runs WHERE task_id='invoice.categorise' ORDER BY run_at DESC LIMIT 1;"
```
Expected: prints a number (e.g. `67.0`) — the current coverage %.

- [ ] **Step 5: Commit**

```bash
git add scripts/metis-observe.sh tests/metis/test_03_observe.sql
git commit -m "feat(metis): OBSERVE stage writes nightly coverage metrics"
```

---

### Task 4: PROPOSE orchestrator + dedupe/benchmark gate — `scripts/metis-categorise-detect.sh`

**Files:**
- Create: `scripts/metis-categorise-detect.sh`
- Test: `tests/metis/test_04_detect.sql`

**Interfaces:**
- Consumes: the four `cognition.fn_detect_categorise_*` functions (Task 1); `metis_psql` (Task 2).
- Produces: `cognition.proposals` rows (status `pending`), skipping any whose signature is in `cognition.proposal_rejections` and any GAP/CORRECTION whose suggested category would mislabel a `cognition.benchmark_labels` row. Signature = `md5(detector||':'||entity_ref||':'||action_kind)`.

- [ ] **Step 1: Write the failing test**

```sql
-- tests/metis/test_04_detect.sql — seed a fixture vendor with a clean sibling +
-- an uncategorised invoice, run the GAP→proposal insert, assert one proposal; then
-- assert a rejection signature suppresses it. All inside a rolled-back txn.
\set ON_ERROR_STOP on
BEGIN;
SET app.current_entity='all'; SET app.current_realm='owner';
-- fixture: vendor 'fixturevendor.test' — one categorised sibling, one NULL
INSERT INTO vendor_invoice_inbox (idempotency_key, source_email_id, account, vendor_domain, vendor_name, subject, received_at, gross_amount, vendor_category, is_statement, status, realm)
VALUES ('mtfix1','m1','info','fixturevendor.test','Fixture','s',now(),100,'kitchen',false,'new','work');
INSERT INTO vendor_invoice_inbox (idempotency_key, source_email_id, account, vendor_domain, vendor_name, subject, received_at, gross_amount, vendor_category, is_statement, status, realm)
VALUES ('mtfix2','m2','info','fixturevendor.test','Fixture','s',now(),200,NULL,false,'new','work');
-- run the proposal insert (mirrors the script body)
INSERT INTO cognition.proposals (task_id,detector,entity_ref,action_kind,action_payload,revert_payload,evidence,impact_gbp,confidence,category_source,predicted_effect,realm)
SELECT 'invoice.categorise', d.detector, d.entity_ref, d.action_kind, d.action_payload, d.revert_payload, d.evidence, d.impact_gbp, d.confidence, d.category_source, d.predicted_effect, d.realm
FROM cognition.fn_detect_categorise_gaps() d
WHERE d.entity_ref='fixturevendor.test'
  AND NOT EXISTS (SELECT 1 FROM cognition.proposal_rejections r
                  WHERE r.task_id='invoice.categorise'
                    AND r.signature = md5(d.detector||':'||d.entity_ref||':'||d.action_kind))
ON CONFLICT (task_id,detector,entity_ref,action_kind) DO NOTHING;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM cognition.proposals
          WHERE entity_ref='fixturevendor.test' AND detector='gap') = 1,
         'expected one GAP proposal for the fixture vendor';
  ASSERT (SELECT action_payload->>'category' FROM cognition.proposals
          WHERE entity_ref='fixturevendor.test' AND detector='gap') = 'kitchen',
         'suggested category should be the majority sibling category';
END $$;
ROLLBACK;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker exec -i homeai-postgres psql -U postgres -d homeai -f - < tests/metis/test_04_detect.sql`
Expected: PASS only if Task 1's detectors exist. If Task 1 incomplete → FAIL `function ... does not exist`. (This test doubles as detector-correctness coverage.)

- [ ] **Step 3: Write the script**

```bash
# scripts/metis-categorise-detect.sh — DETECT→PROPOSE for invoice.categorise.
# Runs the 4 deterministic detectors; inserts proposals; skips rejected signatures
# and benchmark-conflicting category suggestions. Idempotent (ON CONFLICT).
set -uo pipefail
source "$(dirname "$0")/metis/common.sh"
metis_psql <<'SQL'
SET app.current_entity='all'; SET app.current_realm='owner';
WITH det AS (
  SELECT * FROM cognition.fn_detect_categorise_gaps()
  UNION ALL SELECT * FROM cognition.fn_detect_categorise_contradictions()
  UNION ALL SELECT * FROM cognition.fn_detect_categorise_corrections()
  UNION ALL SELECT * FROM cognition.fn_detect_categorise_overbroad(90)
)
INSERT INTO cognition.proposals
  (task_id,detector,entity_ref,action_kind,action_payload,revert_payload,evidence,
   impact_gbp,confidence,category_source,predicted_effect,realm)
SELECT 'invoice.categorise', d.detector, d.entity_ref, d.action_kind, d.action_payload,
       d.revert_payload, d.evidence, d.impact_gbp, d.confidence, d.category_source,
       d.predicted_effect, d.realm
FROM det d
WHERE NOT EXISTS (                                   -- skip rejected signatures
        SELECT 1 FROM cognition.proposal_rejections r
        WHERE r.task_id='invoice.categorise'
          AND r.signature = md5(d.detector||':'||d.entity_ref||':'||d.action_kind))
  AND NOT EXISTS (                                   -- benchmark gate: don't suggest a category
        SELECT 1 FROM cognition.benchmark_labels b   -- that contradicts a frozen label
        WHERE b.task_id='invoice.categorise'
          AND b.key = d.entity_ref
          AND d.action_payload ? 'category'
          AND b.expected <> (d.action_payload->>'category'))
ON CONFLICT (task_id,detector,entity_ref,action_kind) DO UPDATE
  SET impact_gbp = EXCLUDED.impact_gbp,
      evidence   = EXCLUDED.evidence,
      predicted_effect = EXCLUDED.predicted_effect
  WHERE cognition.proposals.status = 'pending';     -- only refresh still-pending ones
SQL
echo "metis-detect: proposals refreshed"
```

- [ ] **Step 4: Run the script, then re-run the test**

Run:
```bash
bash scripts/metis-categorise-detect.sh
docker exec -i homeai-postgres psql -U postgres -d homeai -f - < tests/metis/test_04_detect.sql
docker exec -i homeai-postgres psql -U postgres -d homeai -tAc \
 "SET app.current_realm='owner'; SELECT count(*) FROM cognition.proposals WHERE status='pending';"
```
Expected: test prints `ROLLBACK` (passes); the count is > 0 (real GAP proposals from the live 2,171 uncategorised).

- [ ] **Step 5: Commit**

```bash
git add scripts/metis-categorise-detect.sh tests/metis/test_04_detect.sql
git commit -m "feat(metis): DETECT→PROPOSE with rejection-memory + benchmark gate"
```

---

### Task 5: APPLY approved proposals — `scripts/metis-apply.sh`

**Files:**
- Create: `scripts/metis-apply.sh`
- Test: `tests/metis/test_05_apply.sql`

**Interfaces:**
- Consumes: `cognition.proposals` rows with `status='approved'`; `vendor_category_rules`.
- Produces: for `action_kind='rule_insert'`, an upsert into `vendor_category_rules` and the proposal flipped to `applied` with `applied_at`, `revert_payload={"delete_rule_pattern": <pattern>, "site": <site>}`. Other action_kinds (`rule_narrow`/`rule_retire`) are recorded as `applied` with a human-actioned note (manual enactment in shadow phase). **Never touches `pending` proposals.**

- [ ] **Step 1: Write the failing test**

```sql
-- tests/metis/test_05_apply.sql — approve a rule_insert proposal, run the apply
-- logic, assert the rule exists and proposal is 'applied' with a revert_payload.
\set ON_ERROR_STOP on
BEGIN;
SET app.current_entity='all'; SET app.current_realm='owner';
INSERT INTO cognition.proposals (task_id,detector,entity_ref,action_kind,action_payload,evidence,impact_gbp,status,realm)
VALUES ('invoice.categorise','gap','applyfix.test','rule_insert',
        jsonb_build_object('domain_pattern','applyfix.test','category','kitchen','site','shared','priority',100,'realm','work'),
        '{}'::jsonb, 50, 'approved','work');
-- apply logic (mirrors the script)
WITH appr AS (
  SELECT * FROM cognition.proposals
  WHERE task_id='invoice.categorise' AND status='approved' AND action_kind='rule_insert'
), ins AS (
  INSERT INTO vendor_category_rules (domain_pattern, category, site, priority, realm, vendor_display, notes)
  SELECT a.action_payload->>'domain_pattern', a.action_payload->>'category',
         COALESCE(a.action_payload->>'site','shared'), COALESCE((a.action_payload->>'priority')::int,100),
         COALESCE(a.action_payload->>'realm','work'), a.entity_ref, 'metis proposal #'||a.id
  FROM appr a
  ON CONFLICT (domain_pattern, site) DO NOTHING
  RETURNING domain_pattern
)
UPDATE cognition.proposals p
   SET status='applied', applied_at=now(), decided_by=COALESCE(decided_by,'test'),
       revert_payload=jsonb_build_object('delete_rule_pattern', p.action_payload->>'domain_pattern',
                                         'site', COALESCE(p.action_payload->>'site','shared'))
 WHERE p.task_id='invoice.categorise' AND p.status='approved' AND p.action_kind='rule_insert';
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM vendor_category_rules WHERE domain_pattern='applyfix.test') = 1,
         'rule should be inserted';
  ASSERT (SELECT status FROM cognition.proposals WHERE entity_ref='applyfix.test') = 'applied',
         'proposal should be applied';
  ASSERT (SELECT revert_payload->>'delete_rule_pattern' FROM cognition.proposals WHERE entity_ref='applyfix.test') = 'applyfix.test',
         'revert payload should record the inverse';
END $$;
ROLLBACK;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker exec -i homeai-postgres psql -U postgres -d homeai -f - < tests/metis/test_05_apply.sql`
Expected: PASS as written (the test inlines the logic) — this confirms the SQL is correct before extracting it into the script. *(If FAIL, fix the SQL here first.)*

- [ ] **Step 3: Write the script**

```bash
# scripts/metis-apply.sh — enact human-APPROVED proposals only. Shadow-safe:
# does nothing to 'pending'. rule_insert is auto-enacted; narrow/retire are flagged
# for manual SQL in the shadow phase (logged, status left 'approved').
set -uo pipefail
source "$(dirname "$0")/metis/common.sh"
metis_psql <<'SQL'
SET app.current_entity='all'; SET app.current_realm='owner';
WITH appr AS (
  SELECT * FROM cognition.proposals
  WHERE task_id='invoice.categorise' AND status='approved' AND action_kind='rule_insert'
), ins AS (
  INSERT INTO vendor_category_rules (domain_pattern, category, site, priority, realm, vendor_display, notes)
  SELECT a.action_payload->>'domain_pattern', a.action_payload->>'category',
         COALESCE(a.action_payload->>'site','shared'), COALESCE((a.action_payload->>'priority')::int,100),
         COALESCE(a.action_payload->>'realm','work'), a.entity_ref, 'metis proposal #'||a.id
  FROM appr a
  ON CONFLICT (domain_pattern, site) DO NOTHING
  RETURNING domain_pattern
)
UPDATE cognition.proposals p
   SET status='applied', applied_at=now(),
       revert_payload=jsonb_build_object('delete_rule_pattern', p.action_payload->>'domain_pattern',
                                         'site', COALESCE(p.action_payload->>'site','shared'))
 WHERE p.task_id='invoice.categorise' AND p.status='approved' AND p.action_kind='rule_insert';
\echo 'Approved narrow/retire proposals needing manual enactment:'
SELECT id, action_kind, entity_ref FROM cognition.proposals
 WHERE task_id='invoice.categorise' AND status='approved' AND action_kind IN ('rule_narrow','rule_retire');
SQL
echo "metis-apply: applied approved rule_insert proposals"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker exec -i homeai-postgres psql -U postgres -d homeai -f - < tests/metis/test_05_apply.sql`
Expected: PASS (`ROLLBACK`, no assert failure).

- [ ] **Step 5: Commit**

```bash
git add scripts/metis-apply.sh tests/metis/test_05_apply.sql
git commit -m "feat(metis): APPLY enacts human-approved rule_insert proposals (reversible)"
```

---

### Task 6: MEASURE + auto-corrective — `scripts/metis-measure.sh`

**Files:**
- Create: `scripts/metis-measure.sh`
- Test: `tests/metis/test_06_measure.sql`

**Interfaces:**
- Consumes: `cognition.proposals` with `status='applied'` and `measured_effect IS NULL`; `vendor_invoice_inbox`.
- Produces: writes `measured_effect` (how many invoices the rule now covers); if an applied rule's domain is implicated in a NEW >£1k contradiction, raises a corrective `rule_narrow` proposal with `reverts_proposal_id` set.

- [ ] **Step 1: Write the failing test**

```sql
-- tests/metis/test_06_measure.sql — an applied proposal whose vendor now shows a
-- >£1k multi-category contradiction must spawn a corrective proposal.
\set ON_ERROR_STOP on
BEGIN;
SET app.current_entity='all'; SET app.current_realm='owner';
INSERT INTO cognition.proposals (id,task_id,detector,entity_ref,action_kind,action_payload,status,applied_at,impact_gbp,realm)
VALUES (900001,'invoice.categorise','gap','measfix.test','rule_insert',
        jsonb_build_object('domain_pattern','measfix.test','category','kitchen'),'applied',now(),1500,'work');
-- two categories, >£1k → contradiction signal
INSERT INTO vendor_invoice_inbox (idempotency_key,source_email_id,account,vendor_domain,vendor_name,subject,received_at,gross_amount,vendor_category,is_statement,status,realm)
VALUES ('measf1','mf1','info','measfix.test','MF','s',now(),900,'kitchen',false,'new','work'),
       ('measf2','mf2','info','measfix.test','MF','s',now(),900,'bar',false,'new','work');
-- corrective insert (mirrors script)
INSERT INTO cognition.proposals (task_id,detector,entity_ref,action_kind,action_payload,evidence,impact_gbp,status,reverts_proposal_id,realm)
SELECT 'invoice.categorise','overbroad', p.entity_ref,'rule_narrow',
       jsonb_build_object('domain_pattern',p.entity_ref,'reason','applied rule caused >£1k multi-category'),
       '{}'::jsonb, 1800,'pending', p.id,'work'
FROM cognition.proposals p
WHERE p.status='applied' AND p.id=900001
  AND EXISTS (SELECT 1 FROM vendor_invoice_inbox v WHERE v.vendor_domain=p.entity_ref
              GROUP BY v.vendor_domain
              HAVING count(DISTINCT v.vendor_category) >= 2
                 AND sum(COALESCE(v.gross_amount,0)) > 1000)
ON CONFLICT (task_id,detector,entity_ref,action_kind) DO NOTHING;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM cognition.proposals
          WHERE entity_ref='measfix.test' AND action_kind='rule_narrow' AND reverts_proposal_id=900001) = 1,
         'a corrective rule_narrow proposal should be raised';
END $$;
ROLLBACK;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker exec -i homeai-postgres psql -U postgres -d homeai -f - < tests/metis/test_06_measure.sql`
Expected: PASS as written (logic inlined) — confirms the corrective SQL before scripting it.

- [ ] **Step 3: Write the script**

```bash
# scripts/metis-measure.sh — MEASURE stage: record effect of applied rules and
# auto-raise corrective proposals when an applied rule is implicated in a >£1k
# multi-category contradiction. Recursive close of the loop.
set -uo pipefail
source "$(dirname "$0")/metis/common.sh"
metis_psql <<'SQL'
SET app.current_entity='all'; SET app.current_realm='owner';
-- 1. record measured effect: how many invoices the applied domain now covers
UPDATE cognition.proposals p
   SET measured_effect = jsonb_build_object('now_covering',
         (SELECT count(*) FROM vendor_invoice_inbox v
          WHERE v.vendor_domain = p.entity_ref AND v.vendor_category IS NOT NULL))
 WHERE p.task_id='invoice.categorise' AND p.status='applied' AND p.measured_effect IS NULL;
-- 2. corrective: applied rule whose vendor now shows >£1k multi-category
INSERT INTO cognition.proposals
  (task_id,detector,entity_ref,action_kind,action_payload,evidence,impact_gbp,status,reverts_proposal_id,realm)
SELECT 'invoice.categorise','overbroad', p.entity_ref,'rule_narrow',
       jsonb_build_object('domain_pattern',p.entity_ref,'reason','applied rule caused >£1k multi-category'),
       '{}'::jsonb,
       (SELECT sum(COALESCE(v.gross_amount,0)) FROM vendor_invoice_inbox v WHERE v.vendor_domain=p.entity_ref),
       'pending', p.id,'work'
FROM cognition.proposals p
WHERE p.task_id='invoice.categorise' AND p.status='applied' AND p.action_kind='rule_insert'
  AND EXISTS (SELECT 1 FROM vendor_invoice_inbox v WHERE v.vendor_domain=p.entity_ref
              GROUP BY v.vendor_domain
              HAVING count(DISTINCT v.vendor_category) >= 2
                 AND sum(COALESCE(v.gross_amount,0)) > 1000)
ON CONFLICT (task_id,detector,entity_ref,action_kind) DO NOTHING;
SQL
echo "metis-measure: effects recorded, correctives raised"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker exec -i homeai-postgres psql -U postgres -d homeai -f - < tests/metis/test_06_measure.sql`
Expected: PASS (`ROLLBACK`, no assert failure).

- [ ] **Step 5: Commit**

```bash
git add scripts/metis-measure.sh tests/metis/test_06_measure.sql
git commit -m "feat(metis): MEASURE records effect + auto-raises corrective proposals"
```

---

### Task 7: Telegram digest — `scripts/metis-digest.sh`

**Files:**
- Create: `scripts/metis-digest.sh`
- Test: `tests/metis/test_07_digest.sh`

**Interfaces:**
- Consumes: `cognition.v_proposal_queue`; the existing notifier `scripts/notify-telegram.sh` (already used by `u128-forward-orphans.sh`).
- Produces: a `--dry-run` mode that prints the top-N digest text to stdout (used by the test, no send); without the flag, sends via `notify-telegram.sh`. Default N = 10.

- [ ] **Step 1: Write the failing test**

```bash
# tests/metis/test_07_digest.sh — dry-run prints a header and never sends.
set -euo pipefail
out=$(bash "$(dirname "$0")/../../scripts/metis-digest.sh" --dry-run)
echo "$out" | grep -q "Metis proposals" || { echo "FAIL: missing digest header"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/metis/test_07_digest.sh`
Expected: FAIL — script not found.

- [ ] **Step 3: Write the script**

```bash
# scripts/metis-digest.sh — nightly Telegram digest of top-N pending proposals by £.
# Usage: metis-digest.sh [--dry-run] [N]
set -uo pipefail
source "$(dirname "$0")/metis/common.sh"
DRY=0; N=10
for a in "$@"; do case "$a" in --dry-run) DRY=1;; [0-9]*) N="$a";; esac; done
BODY=$(metis_psql_value "
  SET app.current_realm='owner';
  SELECT COALESCE(string_agg(
    format('• £%s  %s → %s  (%s)', to_char(impact_gbp,'FM999990'), entity_ref,
           COALESCE(action_payload->>'category', action_kind), detector), E'\n'
    ORDER BY impact_gbp DESC), '(none)')
  FROM (SELECT * FROM cognition.v_proposal_queue LIMIT $N) q;")
PENDING=$(metis_psql_value "SET app.current_realm='owner'; SELECT count(*) FROM cognition.proposals WHERE status='pending';")
MSG="📋 Metis proposals — top $N of $PENDING pending (approve in dashboard):
$BODY"
if [ "$DRY" = "1" ]; then
  echo "$MSG"
else
  bash /home_ai/scripts/notify-telegram.sh "$MSG" "metis" >/dev/null 2>&1 || true
  echo "metis-digest: sent ($PENDING pending)"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/metis/test_07_digest.sh`
Expected: `PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/metis-digest.sh tests/metis/test_07_digest.sh
git commit -m "feat(metis): Telegram digest of top-N pending proposals (dry-run testable)"
```

---

### Task 8: Seed the frozen benchmark + wire cron (shadow mode)

**Files:**
- Create: `scripts/metis-seed-benchmark.sh`
- Create: `scripts/metis-nightly.sh` (orchestrates observe→detect→measure→digest; NOT apply)
- Test: `tests/metis/test_08_nightly.sh`

**Interfaces:**
- Consumes: all scripts from Tasks 3–7.
- Produces: `metis-seed-benchmark.sh` populates `cognition.benchmark_labels` from the current most-confident vendor→category pairs (vendors with a single consistent category and ≥3 invoices). `metis-nightly.sh` runs OBSERVE→DETECT→MEASURE→DIGEST in order (deliberately excludes APPLY — shadow mode). Cron entry added to JOLY's crontab.

- [ ] **Step 1: Write the failing test**

```bash
# tests/metis/test_08_nightly.sh — nightly orchestrator runs all stages without apply.
set -euo pipefail
out=$(bash "$(dirname "$0")/../../scripts/metis-nightly.sh" --dry-run 2>&1)
echo "$out" | grep -q "metis-observe" || { echo "FAIL: observe not run"; exit 1; }
echo "$out" | grep -q "metis-detect"  || { echo "FAIL: detect not run"; exit 1; }
echo "$out" | grep -qi "apply" && { echo "FAIL: apply must NOT run in nightly"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/metis/test_08_nightly.sh`
Expected: FAIL — `metis-nightly.sh` not found.

- [ ] **Step 3: Write the benchmark seeder**

```bash
# scripts/metis-seed-benchmark.sh — freeze high-confidence vendor→category labels.
set -uo pipefail
source "$(dirname "$0")/metis/common.sh"
metis_psql <<'SQL'
SET app.current_entity='all'; SET app.current_realm='owner';
INSERT INTO cognition.benchmark_labels (task_id, key, expected, added_by, realm)
SELECT 'invoice.categorise', vendor_domain, max(vendor_category), 'seed', 'work'
FROM vendor_invoice_inbox
WHERE vendor_category IS NOT NULL AND is_statement=false AND status NOT IN ('duplicate','ignored')
GROUP BY vendor_domain
HAVING count(DISTINCT vendor_category)=1 AND count(*)>=3
ON CONFLICT (task_id,key) DO NOTHING;
SQL
echo "metis-seed-benchmark: frozen labels seeded"
```

- [ ] **Step 4: Write the nightly orchestrator**

```bash
# scripts/metis-nightly.sh — SHADOW-MODE loop: observe→detect→measure→digest.
# Deliberately excludes apply (human approves via dashboard; apply runs separately).
set -uo pipefail
D=""; [ "${1:-}" = "--dry-run" ] && D="--dry-run"
cd /home_ai
echo "metis-observe"; bash scripts/metis-observe.sh ${D:+>/dev/null} || true
echo "metis-detect";  bash scripts/metis-categorise-detect.sh ${D:+>/dev/null} || true
echo "metis-measure"; bash scripts/metis-measure.sh ${D:+>/dev/null} || true
bash scripts/metis-digest.sh ${D:-} 10
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/metis/test_08_nightly.sh`
Expected: `PASS`.

- [ ] **Step 6: Seed the benchmark and add the cron entry**

Run:
```bash
bash scripts/metis-seed-benchmark.sh
( crontab -l 2>/dev/null; \
  echo '45 6 * * * cd /home_ai && bash scripts/metis-nightly.sh >> /home_ai/logs/metis-nightly.log 2>&1' ) | crontab -
crontab -l | grep metis-nightly
```
Expected: the `metis-nightly` line prints (runs 06:45, after the 06:30 categorise sweep).

- [ ] **Step 7: Commit**

```bash
git add scripts/metis-seed-benchmark.sh scripts/metis-nightly.sh tests/metis/test_08_nightly.sh
git commit -m "feat(metis): benchmark seeder + shadow-mode nightly orchestrator + cron"
```

---

### Task 9: Shadow validation run + docs

**Files:**
- Create: `docs/metis-runbook.md`
- Modify: `docs/SYSTEM_ARCHITECTURE.md` (add a Metis bullet to §4 — this file is NOT in the concurrent-work boundary list, safe to edit)

**Interfaces:** none (operational).

- [ ] **Step 1: Run the full nightly once for real and inspect**

Run:
```bash
bash scripts/metis-nightly.sh
docker exec -i homeai-postgres psql -U postgres -d homeai -tAc \
 "SET app.current_realm='owner';
  SELECT detector, count(*), round(sum(impact_gbp)) gbp
  FROM cognition.proposals WHERE status='pending' GROUP BY detector ORDER BY 3 DESC;"
```
Expected: a breakdown like `gap | N | £X` — real proposals generated from the live backlog, none applied.

- [ ] **Step 2: Spot-check 5 proposals against reality**

Run:
```bash
docker exec -i homeai-postgres psql -U postgres -d homeai -tAc \
 "SET app.current_realm='owner';
  SELECT entity_ref, action_payload->>'category', impact_gbp
  FROM cognition.v_proposal_queue LIMIT 5;"
```
Expected: each vendor→category looks correct. **If any is wrong, the detector's majority-vote logic needs a fix — stop and revisit Task 1 before enabling apply.**

- [ ] **Step 3: Write the runbook**

```markdown
# Metis runbook
Shadow loop runs 06:45 nightly: observe→detect→measure→digest (NO apply).
- Approve: set proposal status. `UPDATE cognition.proposals SET status='approved', decided_by='jo', decided_at=now() WHERE id=…;`
- Reject (remembers it): INSERT a row into cognition.proposal_rejections with signature md5(detector||':'||entity_ref||':'||action_kind), then set status='rejected'.
- Enact approved: `bash scripts/metis-apply.sh` (rule_insert auto; narrow/retire listed for manual SQL).
- Metrics: `SELECT run_at, metrics->>'coverage_pct' FROM cognition.task_runs ORDER BY run_at DESC LIMIT 14;`
- HARD BOUNDARY: Metis never edits invoice-pipeline files (see spec §6a).
```

- [ ] **Step 4: Add the architecture-doc bullet**

Add to `docs/SYSTEM_ARCHITECTURE.md` §4, after the Gaming-mode bullet:
```markdown
- **Metis self-improvement loop** — `scripts/metis-nightly.sh` (06:45, shadow). OBSERVE→DETECT→PROPOSE→REVIEW→MEASURE beside each task; deterministic detectors, human-gated apply (`metis-apply.sh`), frozen `cognition.benchmark_labels`. Pilot: invoice categorisation. Tables in `cognition.*`. Spec: `docs/superpowers/specs/2026-06-20-metis-task-self-improvement-loop-design.md`. Reads invoice-pipeline outputs read-only; never edits those files.
```

- [ ] **Step 5: Commit**

```bash
git add docs/metis-runbook.md docs/SYSTEM_ARCHITECTURE.md
git commit -m "docs(metis): runbook + architecture-doc entry; shadow run validated"
```

---

### Task 10 (ENABLEMENT — do NOT run until a shadow week passes): turn on Hermes auto-approve for the provably-safe class

**Files:**
- Create: `scripts/metis-autoapprove.sh`

**Interfaces:**
- Consumes: pending `gap` proposals; `cognition.benchmark_labels`.
- Produces: flips to `auto_approved` ONLY proposals that are `detector='gap'` + `category_source='deterministic'` + `impact_gbp <= 250` + the vendor has a benchmark label equal to the suggested category. Then calls `metis-apply.sh`.

- [ ] **Step 1: Precondition gate (manual)**

Confirm ≥7 nightly runs exist and zero applied proposals were later reverted:
```bash
docker exec -i homeai-postgres psql -U postgres -d homeai -tAc \
 "SET app.current_realm='owner';
  SELECT (SELECT count(*) FROM cognition.task_runs WHERE task_id='invoice.categorise') runs,
         (SELECT count(*) FROM cognition.proposals WHERE status='reverted') reverted;"
```
Expected: `runs >= 7` and `reverted = 0`. **If reverted > 0, do not enable — investigate first.**

- [ ] **Step 2: Write the auto-approve script**

```bash
# scripts/metis-autoapprove.sh — narrow provably-safe auto-approval, then apply.
set -uo pipefail
source "$(dirname "$0")/metis/common.sh"
CEIL="${1:-250}"
metis_psql <<SQL
SET app.current_entity='all'; SET app.current_realm='owner';
UPDATE cognition.proposals p
   SET status='approved', decided_by='hermes-auto', decided_at=now()
 WHERE p.task_id='invoice.categorise' AND p.status='pending'
   AND p.detector='gap' AND p.category_source='deterministic'
   AND p.impact_gbp <= $CEIL
   AND EXISTS (SELECT 1 FROM cognition.benchmark_labels b
               WHERE b.task_id='invoice.categorise' AND b.key=p.entity_ref
                 AND b.expected = p.action_payload->>'category');
SQL
bash "$(dirname "$0")/metis-apply.sh"
echo "metis-autoapprove: safe class approved (ceil £$CEIL) + applied"
```

- [ ] **Step 3: Commit (but leave OUT of cron until you decide to enable)**

```bash
git add scripts/metis-autoapprove.sh
git commit -m "feat(metis): provably-safe auto-approve gate (manual until shadow week passes)"
```

---

## Deferred (explicitly NOT in this plan — gated on concurrent work)

- **P4 — is-invoice adopter.** Wait until the parallel session's `scripts/invoice-line-extract.py` (`classify_doc()`) has settled. Then add `scripts/metis-isinvoice-detect.sh` observing its statement/invoice verdicts → `invoice_noise_*` / threshold proposals. Do not edit `invoice-line-extract.py`.
- **P5 — line-extraction telemetry.** Wrap the existing `learned_example()` layout-learning loop with OBSERVE/MEASURE only (does priming lift cross-foot pass-rate?). Add no logic to `invoice-line-extract.py`.
- **Dashboard "Proposals" widget.** `services/build-dashboard/main.py` is in active flux (uncommitted changes by other work). Defer until it settles; then add a read-only route over `cognition.v_proposal_queue`. The Telegram digest (Task 7) covers review in the interim.

---

## Self-Review

**Spec coverage:** §2 envelope → Tasks 3–8; §3 contract (observe/detect/apply/revert) → Tasks 3,4,5,6; §4 categorisation detectors (gap/contradiction/correction/overbroad) → Task 1 functions + Task 4; §6 data model → Task 1; §6a boundaries → Global Constraints + Deferred; §7 review surfaces (digest now, dashboard deferred) → Task 7 + Deferred; §8 MEASURE/recursion/frozen benchmark → Task 6 + Task 8 seeder + Task 4 gate; §9 rollout P1–P3 → Tasks 1–10, P4/P5 → Deferred; §11 defaults (nightly 06:45, £250 ceiling, top-10, 90-day dead) → Tasks 8,10,1,7. Is-invoice (§5) intentionally deferred per the concurrent-work boundary.

**Placeholder scan:** none — every step has runnable SQL/bash and an expected result.

**Type consistency:** `cognition.detection` composite (Task 1) is the return type consumed verbatim by the detect insert (Task 4). Signature formula `md5(detector||':'||entity_ref||':'||action_kind)` identical in Task 4 (gate) and Task 9 runbook (reject). `revert_payload` keys (`delete_rule_pattern`,`site`) consistent across Task 5 script/test. `status` values match the Task 1 CHECK constraint everywhere.
