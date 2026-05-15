# U54 — Pipeline Stability + Dojo↔TouchOffice Reconciliation Foundation

**Prereqs**: U53 shipped (R5 + V67 + U50 closeout). Dojo master table `dojo_transactions` is live (9,215 rows / 01-Jan → 14-May-2026) with `v_dojo_daily` view and `/dojo` page.

**Realm**: cross-cutting. T1–T3 touch OWNER infra (event pipeline + alerts). T4–T5 are WORK (cafe + pub takings reconciliation).

**Remote vs in-person**: 100% remote. T1 may need Jo to click "Activate" in the n8n UI if the workflow is in deactivated state — that's a 30-second step, not a blocker. Otherwise unattended ~3h.

**Why this sprint exists**: two production wounds surfaced today.

1. **The `events.email.received` → `emails` table consumer (n8n `master-router` workflow) has been silent since 2026-05-13 16:15.** 157 events are stuck pending; 80 dead letters from `stale_lease_recovery` all carry the identical error `Max retries exceeded — stale on node master-router (downstream not present)`. The classification / invoice-extraction / daily-digest-uncertain widget all read the `emails` table — every one of them is running on >24h-stale data. The heartbeat correctly reports DEGRADED but nobody pages on it. Twelve hours of "look fine on the dashboard" was 2,000+ rows of real ingest going dark.

2. **There is no automated reconciliation between Dojo card takings and the TouchOffice "Card" tender total.** Jo just imported the Dojo CSV explicitly for "future transaction reconciliation workflow". TouchOffice already records the per-site daily Card tender; nothing checks that the two agree. A bartender voiding the wrong sale or a card-machine timeout that drops a transaction goes unnoticed until the bank reconciliation a week later.

This sprint fixes #1 so the email pipeline is alive again, instruments the system so this exact outage gets paged next time, and lays the floor for the Dojo reconciliation that #2 needs — first as a per-day-per-site mismatch view, then as a `reconciliation_flags` row when the delta crosses £1.

**Discipline carry-overs**:
- Rule #1 — verify before done. T1's gate is "the oldest pending event becomes processed within 60 seconds of restart"; T4's gate is "the mismatch view returns a row where delta = 0 ± £1 for at least 5 historical days where TouchOffice + Dojo both have data."
- Rule #5 — scripts-with-prompts beat copy-paste. The reconciliation isn't a one-shot SQL — make it a view + a script that flags new mismatches into `reconciliation_flags` on a schedule.
- Rule #9 — break iteration loop after 3 attempts. If T1's restart-the-workflow path needs a 4th try, abort, capture the n8n logs, document, hand off to fresh session. Trying-the-same-fix-harder on a broken n8n workflow is the classic anti-pattern.
- Rule #10 — audit consumers before replacing producer. T4 introduces `reconciliation_flags` writes; check existing readers (`alertmanager`, Grafana panels) before writing rows with new shapes.

## Tracks

### T1 — Restore the events→emails consumer (~45 min)

**Realm**: owner (n8n + events table are platform-internal).

**Why this is first**: every other track in this sprint that depends on freshness of the `emails` table is silently broken until this comes back. T4's reconciliation view in particular reads `vendor_invoice_inbox` and `dojo_transactions` directly so it works regardless — but if T1 is left for "later", the same outage happens again next week and we're typing the same diagnosis a third time.

**Build**:
- `docker logs --tail 200 homeai-n8n` and `docker exec homeai-n8n wget -qO- http://localhost:5678/healthz` to confirm n8n is up.
- Query the n8n Postgres backend (same DB, schema `n8n`) for workflows with `active=true` and a recent execution failure:
  ```sql
  SELECT id, name, active, "updatedAt"
    FROM n8n.workflow_entity
   WHERE name ILIKE '%router%' OR name ILIKE '%email%' OR name ILIKE '%event%'
   ORDER BY "updatedAt" DESC;
  SELECT "workflowId", "startedAt", "stoppedAt", finished, "data"::text
    FROM n8n.execution_entity
   WHERE "startedAt" > now() - interval '36 hours'
   ORDER BY "startedAt" DESC LIMIT 10;
  ```
- Three plausible failure modes, in decreasing likelihood:
  1. Workflow `master-router` is deactivated (`active=false`). Toggle via the n8n REST API:
     `docker exec homeai-n8n wget -qO- --method=POST http://localhost:5678/api/v1/workflows/<id>/activate -H "X-N8N-API-KEY: $(...vault...)"`.
     If no API key is configured, Jo flips the toggle in the UI (30 sec).
  2. Workflow is active but throws on a missing webhook / missing downstream container. Fix by inspecting `execution_entity.data` for the last failing run and patching the broken node.
  3. The whole n8n process is fine but the worker pool is jammed. `docker restart homeai-n8n`.
- Once the workflow is back, clear the 80 stale-lease dead letters that are blocking `Diag_dead_letter_recent`:
  ```sql
  UPDATE dead_letter
     SET resolved=true,
         resolved_at=now(),
         resolution_notes='auto-resolved by U54 T1 — n8n master-router restored'
   WHERE resolved=false AND pipeline='stale_lease_recovery';
  ```

**Acceptance**:
- `SELECT MIN(created_at) FROM events WHERE event_type='email.received' AND status='pending';` returns NULL (or a timestamp later than T1 start).
- `SELECT MAX(received_at) FROM emails` is within the last hour.
- `SELECT COUNT(*) FROM dead_letter WHERE resolved=false AND pipeline='stale_lease_recovery'` returns 0.
- Heartbeat at T1+15min Telegrams `♥ HH:MM · ok` (no DEGRADED tail).

---

### T2 — Drain the 157 pending events (~30 min)

**Realm**: owner.

**Why**: T1 restores forward processing but doesn't retroactively replay 24h of pending events. The classifier / invoice pipeline depends on them landing in the `emails` table.

**Build**:
- After T1 confirms the workflow is alive, force-claim the pending events:
  ```sql
  UPDATE events SET status='pending', processing_started_at=NULL, processing_node_id=NULL
   WHERE event_type='email.received' AND status='pending'
     AND created_at > now() - interval '36 hours';
  ```
  (no-op writes but bumps `updated_at`-style indexes if any; safe).
- Trigger the n8n workflow manually for any events that don't get picked up within 5 min:
  ```bash
  curl -sX POST http://homeai-n8n:5678/webhook/master-router-replay \
       -H 'Content-Type: application/json' \
       -d '{"replay_since":"2026-05-13T16:00:00Z"}'
  ```
  (Workflow needs a `master-router-replay` webhook node if it doesn't already have one — add it as part of T1.)

**Acceptance**:
- `SELECT COUNT(*) FROM events WHERE event_type='email.received' AND status='pending' AND created_at < now() - interval '5 min';` returns 0.
- New rows visible in `emails` table for the previously-pending event IDs.
- Daily-digest "uncertain classifications" widget re-populates with current-day rows.

---

### T3 — Consumer-stall alert (~30 min)

**Realm**: owner.

**Why**: this outage went 24h without paging because the existing watchdogs check "is the container up" and "are alerts firing" but not "is the backlog growing". We need an alert that fires on the backlog itself.

**Build**:
- New Prometheus alert in `monitoring/alerts/n8n.yml` (or wherever the rest live):
  ```yaml
  - alert: EventConsumerStalled
    expr: pg_event_pending_count > 50
    for: 30m
    labels: { severity: critical }
    annotations:
      summary: "events.email.received pending > 50 for 30+ min"
      runbook: "Restart n8n master-router; see U54 T1."
  ```
- Add the supporting Postgres-exporter query to `monitoring/postgres-exporter/queries.yaml`:
  ```yaml
  pg_event_pending_count:
    query: |
      SELECT COUNT(*) AS count
        FROM events
       WHERE event_type='email.received' AND status='pending'
         AND created_at < now() - interval '15 minutes'
    master: true
    metrics:
      - count: { usage: GAUGE, description: "Stale pending email.received events" }
  ```
- Reload prometheus + postgres-exporter: `docker compose kill -s HUP prometheus postgres-exporter`.

**Acceptance**:
- `curl http://prometheus:9090/api/v1/query?query=pg_event_pending_count` returns a current count.
- Synthetic trigger: temporarily change the threshold to 0 → alert fires within 30m → revert.
- A `runbook` field that points at this sprint plan exists on the alert.

---

### T4 — Dojo ↔ TouchOffice card-tender reconciliation (~60 min)

**Realm**: work (pub + cafe takings).

**Why**: now that `dojo_transactions` and `touchoffice_fixed_totals` both carry per-day per-site totals, the natural daily check is "did the EPoS Card tender total match the Dojo gross". Differences > £1 deserve a human eye — they catch voided sales gone wrong, dropped txns from card-machine timeouts, refund-day mismatches, etc.

**Build**:
- New migration `V69__dojo_touchoffice_reconciliation.sql`:
  - Create `v_dojo_touchoffice_recon` joining `v_dojo_daily` to `touchoffice_fixed_totals` on `(report_date, site)` where label='Card' (verify exact label string in T1 prep). Columns: `date`, `site`, `dojo_gross`, `touchoffice_card`, `delta`, `delta_pct`, `dojo_count`, `flag` ('match' if abs(delta) ≤ 1, 'check' if ≤ 10, 'investigate' if > 10).
  - `reconciliation_flags` table — re-use the existing one if present (per memory there's a `reconciliation_flags` table mentioned in V64a). Check before creating:
    ```sql
    \d reconciliation_flags
    ```
    If it exists, add a row per (date, site) with `flag='investigate'` and `delta > 10`. If not, create a small one:
    ```sql
    CREATE TABLE IF NOT EXISTS reconciliation_flags (
        id BIGSERIAL PRIMARY KEY,
        check_date DATE NOT NULL,
        check_type TEXT NOT NULL,
        site TEXT,
        entity_id INTEGER NOT NULL DEFAULT 1,
        realm TEXT NOT NULL DEFAULT 'work'
            CHECK (realm IN ('owner','work','family','shared')),
        details JSONB NOT NULL,
        resolved BOOLEAN NOT NULL DEFAULT false,
        resolved_at TIMESTAMPTZ,
        resolution_notes TEXT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE (check_date, check_type, site)
    );
    -- RLS — same pattern as dojo_transactions.
    ```
  - Index on `(check_date, check_type)`.
- New script `scripts/dojo-touchoffice-recon.sh`:
  - Reads `v_dojo_touchoffice_recon` for the last 14 days.
  - UPSERTs a `reconciliation_flags` row for any (date, site) where `flag IN ('check','investigate')`; clears existing row if the day flips back to match (e.g. after a Dojo CSV re-import). ON CONFLICT (check_date, check_type, site) DO UPDATE.
  - Cron daily at 07:30 (after the morning Dojo refresh window).

**Acceptance**:
- `SELECT * FROM v_dojo_touchoffice_recon WHERE date BETWEEN '2026-05-07' AND '2026-05-13' ORDER BY date;` returns a row per (date, site) pair. At least 5 should be `flag='match'`.
- `bash scripts/dojo-touchoffice-recon.sh` writes the expected number of `reconciliation_flags` rows (count manually validated against a single `SELECT` over the view).
- Re-running the script is idempotent — second run = 0 inserts, N updates.

---

### T5 — /dojo dashboard reconciliation column + sprint exit (~30 min)

**Realm**: work.

**Build**:
- Extend `/api/dojo/daily` to LEFT JOIN `v_dojo_touchoffice_recon` and return `touchoffice_card`, `delta`, `flag` per row.
- Add three Tabulator columns to `dojo.html`: TouchOffice £ / Delta £ / status pill (green = match, amber = check, red = investigate).
- Telegram pulse: `U54 shipped: n8n consumer restored (157 events drained, 80 DLs resolved), EventConsumerStalled alert live, Dojo↔TouchOffice recon view live, <N> mismatch flags raised over last 14d.`
- Single commit on a fresh branch `u54-pipeline-stability-dojo-recon`:
  ```
  postgres/migrations/V69__dojo_touchoffice_reconciliation.sql
  scripts/dojo-touchoffice-recon.sh
  monitoring/alerts/n8n.yml
  monitoring/postgres-exporter/queries.yaml   (or wherever queries live)
  services/build-dashboard/main.py
  services/build-dashboard/static/dojo.html
  .claude/sprints/U54-pipeline-stability-dojo-recon.md
  STATE.md
  ```
- Per [[feedback_homeai_pre_push_scan]] — entropy-scan staged tree.

**Acceptance**:
- `/dojo` renders three new columns; recent days are mostly green.
- Telegram message received.
- Commit lands locally. Push deferred to user.

## Sequence + acceptance

| # | Track                                  | Effort | Depends on | Gate |
|---|----------------------------------------|--------|------------|------|
| 1 | n8n master-router restored             | 45m    | —          | Pending events drain; `emails` table fresh |
| 2 | Backlog drain                          | 30m    | T1         | Pending count for events > 5min old = 0 |
| 3 | Consumer-stall alert                   | 30m    | T1         | `pg_event_pending_count` metric live; rule reloaded |
| 4 | Dojo ↔ TouchOffice recon               | 60m    | —          | View returns row per (date, site); script idempotent |
| 5 | Dashboard column + commit              | 30m    | T4         | `/dojo` has recon pills; commit on fresh branch |

T1 and T4 are independent — could run in parallel, but the discipline value of restoring service first is high. **Total est**: ~3h 15m.

## What this sprint does NOT do

- **R6 — Bot/AI realm scope** (Haiku/Sonnet call-site scoping): folded into U55.
- **R7 — Backup** (realm-scoped pg_dump): folded into U56.
- **R3 / R4 full Auth** (REALM_ENFORCE=1 flip): in-person, FQDN-blocked.
- **Untracked migrations V58–V62 + V58 product canonical**: housekeeping commit, separate.
- **TouchOffice "Card" tender data quality**: if the tender label isn't `Card` exactly or there are aliasing issues (e.g., separate `Dojo` line), T4 documents what was found and queues the fix for U55.
- **n8n workflow refactor**: T1 restores the existing flow as-is. Any redesign (e.g., replacing the orchestrator with a Python worker) is its own sprint.

## Abort criteria

- T1 fourth attempt at restoring master-router fails. Document the n8n state, restore Telegram visibility (heartbeat clearly says DEGRADED), hand off to fresh session — the next attempt needs Jo at the box to look at the n8n UI.
- T4 finds that `touchoffice_fixed_totals.label` doesn't have a clean `Card` row for either site. Document the data shape, defer the reconciliation half of the sprint, ship T1–T3 as a stand-alone "pipeline stability" commit.
- T2 backlog drain takes > 30 min real time (would mean the consumer is processing 1 event/sec rather than 100 — back-pressure, downstream slow). Document, leave running, move to T3/T4.

Reply `go` to start; this is a single contiguous autonomous run with a Telegram pulse at each track boundary.
