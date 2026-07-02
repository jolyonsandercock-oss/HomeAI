# R0 "Close the Loop" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every pipeline records a heartbeat, every detection reaches Jo (one daily digest) or a self-heal, and the four chronic silence mechanisms (missing heartbeats, alert-row rot, shallow health probes, boot races) are closed.

**Architecture:** Build on the existing `ops.pipeline_registry`/`ops.pipeline_runs`/`ops-run.sh` spine — no new infrastructure. A generator derives a canonical, deduplicated, heartbeat-wrapped crontab + registry seed from the live crontab; a daily digest script reads the three existing detection tables; deep probes and boot recovery extend `u241-supervisor.sh` / `u273-caddy-boot.sh` patterns already in place.

**Tech Stack:** bash, python3 (host), Postgres (docker exec psql), existing Vault-token harvest pattern, Telegram via bot-responder container.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-02-e2e-refactor-design.md` §3 (R0).
- DB access pattern: `docker exec homeai-postgres psql -U postgres -d homeai` (superuser migration is R3, not now).
- `ops.record_pipeline_run(p_name, p_status, p_started, p_rows, p_note)` — FK: name must exist in `ops.pipeline_registry`.
- Heartbeats must NEVER change a wrapped command's exit code (ops-run.sh contract).
- Every new script: `set -euo pipefail`, per-run heartbeat line to stdout (cron-health silent-success rule, memory 2026-06-22).
- Migration numbering: next free is **V279** (check `ls postgres/migrations | sort -V | tail` before writing; duplicates exist historically — do not reuse).
- Crontab edits go through a snapshot + install script; `homeai-cron-guard` reinstalls from snapshot, so the snapshot MUST be updated in the same task as the crontab.
- Commit after every task (repo: /home_ai, branch feat/system-auditor).

---

### Task 1: Canonical crontab + full registry coverage

**Files:**
- Create: `scripts/gen-canonical-crontab.py`
- Create: `scripts/install-crontab.sh`
- Generated (committed): `scripts/crontab.canonical.txt`, `postgres/migrations/V279__pipeline_registry_full_coverage.sql`
- Test: generator dry-run diff + post-install heartbeat query

**Interfaces:**
- Consumes: live `crontab -l`; existing `ops.pipeline_registry` rows (names reused via script_path match).
- Produces: registry rows for every wrapped job (name = snake_case, see NAME_MAP); crontab lines of the form `M H * * * cd /home_ai && bash scripts/ops-run.sh <name> -- <original command> >> <original log> 2>&1`. Later tasks (digest) rely on: every enabled registry row having `freshness_sql` non-null.

- [ ] **Step 1: Snapshot current state**

```bash
cd /home_ai && crontab -l > backups/crontab-pre-R0-$(date +%F).txt
docker exec homeai-postgres psql -U postgres -d homeai -tAc \
  "SELECT name||'|'||COALESCE(script_path,'') FROM ops.pipeline_registry ORDER BY 1" \
  > backups/registry-pre-R0.txt
wc -l backups/crontab-pre-R0-$(date +%F).txt backups/registry-pre-R0.txt
```
Expected: ~73 crontab lines, 22 registry rows.

- [ ] **Step 2: Write the generator**

`scripts/gen-canonical-crontab.py` — reads `crontab -l`, applies DEDUPE (drop-list of exact duplicate lines), EXCLUDE (jobs not wrapped: every-minute pollers, @reboot, system rsync/prune/sampler), NAME_MAP (script basename → registry name, reusing existing registry names by script_path match), and emits both artifacts.

```python
#!/usr/bin/env python3
"""Generate the canonical heartbeat-wrapped crontab + registry seed from the
live crontab. Deterministic; run with --check to diff against committed output.
Policy:
  - DEDUPE: for each key in DUPE_KEEP, keep exactly the listed line-substring
    variant, drop other lines whose command contains the key.
  - EXCLUDE (not wrapped, kept verbatim): every-minute jobs (cron-health covers
    liveness), @reboot, rsync mirror, docker prune, gpu sampler, snag-trigger.
  - Everything else: wrap with ops-run.sh under NAME_MAP[basename]; jobs already
    wrapped (ops-run.sh present) pass through unchanged.
  - Registry seed: one row per wrapped name, ON CONFLICT DO NOTHING; freshness =
    self-referential last-ok-run with SLA = max(2x cadence hours, 2), unless the
    name already exists (existing rows keep their data-level freshness_sql).
"""
import re, subprocess, sys, pathlib

RAW = subprocess.run(["crontab", "-l"], capture_output=True, text=True, check=True).stdout

DUPE_KEEP = {  # command-substring -> substring that identifies the ONE variant to keep
    "u163-reviews-simple.sh": "bash /home_ai/scripts/u163-reviews-simple.sh",
    "u160-breakfast-send.py": "set -a && . ./.env",   # needs BREAKFAST_TOKEN_SECRET
    "u160-breakfast-kitchen.py": "set -a && . ./.env",
    "weather-sync.py": "docker exec -i",              # host-file form survives recreate
    "backups/restic-local/": "--stats",               # keep the --stats rsync
}
EXCLUDE_SUBSTR = [
    "u33-bot-responder.sh", "u66-telegram-bot.sh",    # every-minute
    "u29-instructions-poll.sh",                        # */2
    "@reboot", "docker image prune", "rsync -a",
    "gpu-power-sample.sh", "snag-trigger.sh",
    "ops-run.sh",                                      # already wrapped
    "partition-maintenance",                           # replaced in Task 8
]
NAME_MAP = {  # script basename -> registry name (existing names verified in Step 3)
    "u241-supervisor.sh": "supervisor", "u33-rejection-digest.sh": "rejection_digest",
    "u62-calendar-sync.sh": "calendar_sync", "u165-freshness-watcher.sh": "freshness_watcher_u165",
    "u33-touchoffice-realtime.sh": "touchoffice_realtime", "u54-pipeline-watchdog.sh": "pipeline_watchdog_u54",
    "u62-paperless-sync.sh": "paperless_sync", "hermes-sentinel.sh": "hermes_sentinel",
    "cron-health-check.py": "cron_health_check", "touchoffice-to-epos.py": "touchoffice_epos_bridge",
    "hermes-proposal-watch.sh": "hermes_proposal_watch", "u239-event-close-sweep.sh": "event_close_sweep",
    "u272-dashboard-watchdog.sh": "dashboard_watchdog", "u33-data-lane-router.sh": "data_lane_router",
    "u68-doc-classify.sh": "doc_classify", "renew-n8n-vault-token.sh": "n8n_token_renew",
    "u163-reviews-simple.sh": "reviews_scrape", "u29-heartbeat.sh": "u29_heartbeat",
    "u160-breakfast-send.py": "breakfast_send", "backup-nightly.sh": "backup_nightly",
    "auto-classify.py": "auto_classify", "u160-breakfast-kitchen.py": "breakfast_kitchen",
    "u133-scrape-tides.py": "tides_scrape", "u29-workforce-sync.sh": "workforce_sync",
    "u128-xero-parse.sh": "xero_parse", "u268-britishgas-portal.sh": "britishgas_portal",
    "u274-touchoffice-headoffice-backfill.sh": "touchoffice_headoffice_backfill",
    "u271-resolve-invoices.sh": "counterparty_resolve_invoices", "u135-dojo-inbox-sweep.sh": "dojo_inbox_sweep",
    "u236-marketing-sweep.sh": "marketing_sweep", "run-bridge.sh": "hermes_memory_bridge",
    "u35-invoice-pdf-extract.sh": "invoice_pdf_extract", "u47-tanda-timesheets-sync.sh": "tanda_timesheets",
    "u50-apply-feedback.sh": "feedback_apply", "u281-vision-ocr-drain.py": "vision_ocr_drain",
    "u50-stale-ack.sh": "alert_stale_ack", "u27-touchoffice-daily.sh": "touchoffice_daily",
    "u126-dext-export.sh": "dext_sweep", "u128-forward-orphans.sh": "invoice_forward_orphans",
    "u28-caterbook-daily.sh": "caterbook_daily", "weather-sync.py": "weather_sync",
    "u286-caterbook-guest-sync.sh": "caterbook_guest_sync", "projA-daily.sh": "proja_daily",
    "u128-xero-export.sh": "xero_export", "claude-day.sh": "claude_day",
    "u125-pdf-attachment-fetch.sh": "invoice_pdf_attach_fetch", "update-master-status.sh": "master_status_update",
    "u95-harvest-cron.sh": "invoice_harvester", "u280-rota-alert.sh": "rota_alert",
    "u250-resume-watchdog.sh": "resume_watchdog", "u-invoice-pdf-date-sweep.sh": "invoice_date_sweep",
    "u-invoice-line-sweep.sh": "invoice_line_sweep", "u-pipeline-freshness-watchdog.sh": "pipeline_freshness_watchdog",
    "u-invoice-categorise-sweep.sh": "invoice_categorise", "u-natwest-inbox-sweep.sh": "natwest_inbox_sweep",
    "u-drinks-classify-sweep.sh": "drinks_classify", "u-deadletter-hygiene.sh": "deadletter_hygiene",
    "u-revenue-recon-check.sh": "revenue_recon_check", "u62-tanda-sync.sh": "tanda_sync",
    "u133-tides.py": "tides_scrape", "system_auditor": "system_auditor",
}

def cadence_hours(schedule):
    m = re.match(r"\*/(\d+) \* \* \* \*", schedule)
    if m: return max(2, 2 * int(m.group(1)) / 60)
    if re.match(r"\d+ \*/(\d+)", schedule):
        return max(2, 2 * int(re.search(r"\*/(\d+)", schedule).group(1)))
    if re.match(r"[\d,]+ \* \* \* \*", schedule): return 2      # hourly
    if "* * 1-5" in schedule or re.match(r"\d+ \d+ \* \* \d", schedule): return 80  # weekly-ish
    if re.match(r"\d+ \d+ \d+ \* \*", schedule): return 24 * 33  # monthly
    return 26                                                    # daily default

def parse(line):
    parts = line.split()
    schedule, cmd = " ".join(parts[:5]), " ".join(parts[5:])
    return schedule, cmd

def main():
    check = "--check" in sys.argv
    kept, seen_keep = [], set()
    for line in RAW.splitlines():
        s = line.strip()
        if not s or s.startswith("#"): continue
        dropped = False
        for key, keep_marker in DUPE_KEEP.items():
            if key in s:
                if keep_marker in s and key not in seen_keep: seen_keep.add(key)
                else: dropped = True
                break
        if not dropped: kept.append(s)

    out_lines, seed = [], []
    for s in kept:
        if any(x in s for x in EXCLUDE_SUBSTR):
            out_lines.append(s); continue
        schedule, cmd = parse(s)
        base = next((b for b in NAME_MAP if b in cmd), None)
        if base is None:
            print(f"WARN: no NAME_MAP entry, kept unwrapped: {s}", file=sys.stderr)
            out_lines.append(s); continue
        name = NAME_MAP[base]
        # split trailing log redirection so ops-run passthrough still reaches the log
        m = re.match(r"(.*?)(\s*(?:>>|2>&1|\|\s*tee).*)$", cmd)
        core, redir = (m.group(1).strip(), m.group(2)) if m else (cmd, "")
        core = re.sub(r"^cd /home_ai && ", "", core)
        out_lines.append(f"{schedule} cd /home_ai && bash scripts/ops-run.sh {name} -- {core}{redir}")
        sla = cadence_hours(schedule)
        seed.append((name, "sweep", base, schedule, sla))

    canonical = "\n".join(out_lines) + "\n"
    seed_sql = ["-- V279: full pipeline_registry coverage (generated by gen-canonical-crontab.py)"]
    for name, kind, base, schedule, sla in seed:
        seed_sql.append(
            "INSERT INTO ops.pipeline_registry(name,kind,script_path,schedule_cron,freshness_sql,freshness_sla_hours,notes)\n"
            f"VALUES ('{name}','{kind}','scripts/{base}','{schedule}',\n"
            f"        'SELECT max(finished_at) FROM ops.pipeline_runs WHERE name=''{name}'' AND status=''ok''',{sla},\n"
            "        'R0 heartbeat coverage') ON CONFLICT (name) DO NOTHING;")
    seed_sql.append(
        "INSERT INTO ops.pipeline_registry(name,kind,script_path,schedule_cron,freshness_sql,freshness_sla_hours,notes)\n"
        "VALUES ('system_auditor','audit','scripts/u-system-auditor.py','30 5 * * *',\n"
        "        'SELECT max(finished_at) FROM ops.pipeline_runs WHERE name=''system_auditor'' AND status=''ok''',26,\n"
        "        'R0: nightly drift/integrity auditor') ON CONFLICT (name) DO NOTHING;")
    sql = "\n".join(seed_sql) + "\n"

    ct, mig = pathlib.Path("scripts/crontab.canonical.txt"), pathlib.Path("postgres/migrations/V279__pipeline_registry_full_coverage.sql")
    if check:
        ok = ct.read_text() == canonical and mig.read_text() == sql
        print("CHECK", "PASS" if ok else "FAIL"); sys.exit(0 if ok else 1)
    ct.write_text(canonical); mig.write_text(sql)
    print(f"wrote {ct} ({len(out_lines)} lines) and {mig} ({len(seed)+1} seed rows)")

if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Generate and review**

```bash
cd /home_ai && python3 scripts/gen-canonical-crontab.py
diff <(crontab -l | grep -vE '^#|^$') scripts/crontab.canonical.txt | head -80
docker exec homeai-postgres psql -U postgres -d homeai -tAc "SELECT name, script_path FROM ops.pipeline_registry ORDER BY 1"
```
Review checks: (a) every WARN from the generator is either added to NAME_MAP or consciously excluded; (b) each name in the seed that matches an EXISTING registry row must reference the same script — where the registry already has the name (e.g. `invoice_harvester`), the seed's ON CONFLICT keeps the existing (better) freshness_sql; (c) duplicates gone: exactly one line each for u163/u160-send/u160-kitchen/weather-sync/rsync; (d) `update-master-status.sh` line now has `cd /home_ai &&` (the wrap adds it — this fixes the 30-day MASTER.md break); (e) freshness/dev-null jobs (`u-pipeline-freshness-watchdog`, `u-invoice-categorise-sweep`) now log via ops-run passthrough — change their redirect from `>/dev/null 2>&1` to `>> /home_ai/logs/<name>.cron.log 2>&1` manually in the canonical file if the generator kept /dev/null.

- [ ] **Step 4: Write the installer**

`scripts/install-crontab.sh`:
```bash
#!/usr/bin/env bash
# Install scripts/crontab.canonical.txt as joly's crontab, with backup + guard resync.
set -euo pipefail
cd /home_ai
SNAP=backups/crontab-replaced-$(date +%F-%H%M).txt
crontab -l > "$SNAP"
crontab scripts/crontab.canonical.txt
# cron-guard reinstalls from its snapshot — refresh it or it will revert us
GUARD_SNAP=$(grep -oE '[^ ]*crontab[^ ]*snapshot[^ ]*' scripts/homeai-cron-guard.sh | head -1 || true)
[ -n "$GUARD_SNAP" ] && cp scripts/crontab.canonical.txt "$GUARD_SNAP" && echo "guard snapshot refreshed: $GUARD_SNAP"
echo "installed $(crontab -l | grep -cvE '^#|^$') lines (backup: $SNAP)"
```

- [ ] **Step 5: Apply migration, install, verify heartbeats**

```bash
cd /home_ai
docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 < postgres/migrations/V279__pipeline_registry_full_coverage.sql
bash scripts/install-crontab.sh
# wait for the next hourly boundary (u125 at :05, deadletter at :25), then:
docker exec homeai-postgres psql -U postgres -d homeai -tAc \
 "SELECT name, max(finished_at) FROM ops.pipeline_runs WHERE finished_at > now()-interval '2 hours' GROUP BY 1 ORDER BY 2 DESC LIMIT 20"
```
Expected: new names (e.g. `invoice_pdf_attach_fetch`, `deadletter_hygiene`, plus whichever */5–*/30 jobs fired) appear with fresh runs. Also verify one wrapped job's log file still receives its normal output (ops-run passthrough): `tail -3 /home_ai/logs/u125-pdf-fetch.log`.

- [ ] **Step 6: Commit**

```bash
cd /home_ai && git add scripts/gen-canonical-crontab.py scripts/install-crontab.sh scripts/crontab.canonical.txt postgres/migrations/V279__pipeline_registry_full_coverage.sql
git commit -m "feat(ops): R0.1 canonical crontab — heartbeat-wrap all jobs, dedupe, full registry seed"
```

---

### Task 2: Stuck-processing reaper + pipeline_runs retention

**Files:**
- Modify: `scripts/u-deadletter-hygiene.sh` (extend the SQL block)

**Interfaces:**
- Consumes: `events(status, processing_started_at, retry_count)`; `ops.pipeline_runs(finished_at)`.
- Produces: hourly reset of events stuck `processing` >1h (bounded by retry_count<3, matching claim semantics); pipeline_runs rows older than 30 days deleted.

- [ ] **Step 1: Capture the before-state (failing check)**

```bash
docker exec homeai-postgres psql -U postgres -d homeai -tAc \
 "SELECT count(*) FROM events WHERE status='processing' AND processing_started_at < now()-interval '1 hour'"
```
Expected: >0 if any n8n restart stranded claims (today's restarts stranded some); note the number.

- [ ] **Step 2: Add reaper + retention to the hygiene SQL**

In `scripts/u-deadletter-hygiene.sh`, extend the heredoc SQL (after the `bump` CTE SELECT) with:
```sql
-- 3. stuck-processing reaper: claims stranded by restarts go back to pending
WITH reaped AS (
  UPDATE events SET status='pending', processing_started_at=NULL, processing_node_id=NULL,
         retry_count=COALESCE(retry_count,0)+1
  WHERE status='processing' AND processing_started_at < now() - interval '1 hour'
    AND COALESCE(retry_count,0) < 3
  RETURNING 1)
SELECT count(*) FROM reaped;
-- 4. pipeline_runs retention (heartbeats are high-volume now)
DELETE FROM ops.pipeline_runs WHERE finished_at < now() - interval '30 days';
```
And extend the `read -r` line to capture the third count: `read -r PHANTOM REDRIVEN REAPED <<<"$(...)"`, plus add `reaped=$REAPED` to the echo line and `OPS_ROWS=$((PHANTOM + REDRIVEN + REAPED))`.

- [ ] **Step 3: Run and verify**

```bash
bash /home_ai/scripts/u-deadletter-hygiene.sh
docker exec homeai-postgres psql -U postgres -d homeai -tAc \
 "SELECT count(*) FROM events WHERE status='processing' AND processing_started_at < now()-interval '1 hour'"
```
Expected: script prints `reaped=<N>` matching Step 1's count; second query returns 0.

- [ ] **Step 4: Commit**

```bash
cd /home_ai && git add scripts/u-deadletter-hygiene.sh && git commit -m "feat(ops): R0.2 stuck-processing reaper + pipeline_runs 30d retention"
```

---

### Task 3: Alert-row hygiene (expire stale, fix per-day fingerprints)

**Files:**
- Modify: `scripts/u50-stale-ack.sh` (add auto-resolve block)
- Investigate/modify: n8n workflow `diagnostics-v1` (fingerprint suffix bug)

**Interfaces:**
- Consumes: `system_alerts(fingerprint, alertname, status, last_updated_at, acknowledged)`.
- Produces: firing rows not refreshed for >72h become `status='resolved'` with a note; the digest (Task 4) can then trust `status='firing'`.

- [ ] **Step 1: Inspect the rot**

```bash
docker exec homeai-postgres psql -U postgres -d homeai -tAc \
 "SELECT alertname, status, last_updated_at::date, count(*) FROM system_alerts WHERE status='firing' GROUP BY 1,2,3 ORDER BY 3"
```
Expected: rows with last_updated_at weeks old (e.g. `Diag_firing_alerts` suffixed fingerprints from June) — these are the rot.

- [ ] **Step 2: Add auto-resolve to u50-stale-ack.sh**

Append after the existing ack UPDATE (same psql connection pattern the script already uses):
```sql
UPDATE system_alerts SET status='resolved', ends_at=now(),
       notes=COALESCE(notes,'')||' [auto-resolved: not refreshed >72h, R0.3]'
 WHERE status='firing' AND last_updated_at < now() - interval '72 hours';
```

- [ ] **Step 3: Check diagnostics-v1 fingerprint construction**

```bash
docker exec homeai-postgres psql -U postgres -d homeai -tAc \
 "SELECT e->>'name', left(e->'parameters'->>'query',300) FROM workflow_entity we
  JOIN workflow_history wh ON wh.\"versionId\"=we.\"activeVersionId\", json_array_elements(wh.nodes::json) e
  WHERE we.id='diagnostics-v1' AND e->'parameters'->>'query' ILIKE '%fingerprint%'"
```
If the INSERT builds `fingerprint` with a date/random suffix (the June rows were `diag_firing_alerts_681ef0f5`), patch it to the stable form (`'diag_'||lower(alertname)`) using the workflow_history+repoint pattern (`scripts/p6-fix-parse-regex.py` is the template — new script `scripts/diag-fix-fingerprint.py`). If the current version is already stable (July rows suggest it may have been fixed), record that in the commit message and skip the patch.

- [ ] **Step 4: Run and verify**

```bash
bash /home_ai/scripts/u50-stale-ack.sh
docker exec homeai-postgres psql -U postgres -d homeai -tAc \
 "SELECT count(*) FROM system_alerts WHERE status='firing' AND last_updated_at < now()-interval '72 hours'"
```
Expected: 0. Remaining firing rows are all recent (genuinely live).

- [ ] **Step 5: Commit**

```bash
cd /home_ai && git add scripts/u50-stale-ack.sh scripts/diag-fix-fingerprint.py 2>/dev/null; git commit -m "feat(ops): R0.3 alert-row hygiene — 72h auto-resolve + stable diag fingerprints"
```

---

### Task 4: Daily ops digest to Telegram

**Files:**
- Create: `scripts/u-ops-digest.sh`
- Modify: `scripts/crontab.canonical.txt` (+ reinstall) — add `45 7 * * * cd /home_ai && bash scripts/ops-run.sh ops_digest -- bash scripts/u-ops-digest.sh >> /home_ai/logs/ops-digest.log 2>&1`; add `ops_digest` registry row in the same style as V279 rows (V280 micro-migration or psql INSERT recorded in the script header).

**Interfaces:**
- Consumes: `ops.check_freshness()` (name/newest/sla_hours/age_hours/status), `system_alerts(status='firing')`, `mart.exceptions(status='open')`.
- Produces: one Telegram message per morning; silent-OK is forbidden — an all-green day sends "all green" (one line) so absence of the digest itself is a signal.

- [ ] **Step 1: Write the digest script**

```bash
#!/usr/bin/env bash
# u-ops-digest.sh — one morning Telegram digest: what is broken and for how long.
set -euo pipefail
echo "START $(date -Is)"
VT=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
PW=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=password secret/postgres)
psqlc(){ docker exec -e PGPASSWORD="$PW" homeai-postgres psql -U postgres -d homeai -tA -F'|' -c "$1"; }

STALE=$(psqlc "SELECT name||' age='||COALESCE(age_hours::text,'n/a')||'h (sla '||sla_hours||'h)'
               FROM ops.check_freshness() WHERE status IN ('STALE','NO_DATA') ORDER BY age_hours DESC NULLS LAST")
ALERTS=$(psqlc "SELECT alertname||' ['||COALESCE(severity,'?')||'] since '||to_char(starts_at,'MM-DD')||
                CASE WHEN acknowledged THEN ' (acked)' ELSE '' END
                FROM system_alerts WHERE status='firing' ORDER BY starts_at")
EXC=$(psqlc "SELECT kind||': '||left(summary,60)||' ('||to_char(raised_at,'MM-DD')||')'
             FROM mart.exceptions WHERE status='open' ORDER BY raised_at DESC LIMIT 15")

BODY=""
[ -n "$STALE" ]  && BODY+=$'\n📉 Stale pipelines:\n'"$(echo "$STALE" | sed 's/^/  • /')"
[ -n "$ALERTS" ] && BODY+=$'\n🚨 Firing alerts:\n'"$(echo "$ALERTS" | sed 's/^/  • /')"
[ -n "$EXC" ]    && BODY+=$'\n⚠️ Open exceptions:\n'"$(echo "$EXC" | sed 's/^/  • /')"
[ -z "$BODY" ]   && BODY=$'\n✅ all green'
MSG="🩺 Ops digest $(date +%a\ %d\ %b)${BODY}"

docker exec -e MSG="$MSG" homeai-bot-responder python -c "
import os, urllib.request, urllib.parse, json
req = urllib.request.Request('http://vault:8200/v1/secret/data/telegram',
    headers={'X-Vault-Token': os.environ['VAULT_TOKEN']})
d = json.loads(urllib.request.urlopen(req, timeout=5).read())['data']['data']
req = urllib.request.Request(f\"https://api.telegram.org/bot{d['bot_token']}/sendMessage\",
    data=urllib.parse.urlencode({'chat_id': d['chat_id'], 'text': os.environ['MSG'][:4000]}).encode())
print('sent:', json.loads(urllib.request.urlopen(req, timeout=10).read()).get('ok'))
"
echo "OPS_ROWS=$( [ -n "$STALE" ] && echo "$STALE" | wc -l || echo 0 )"
echo "DONE $(date -Is)"
```
Note: bot-responder has `VAULT_TOKEN` in its env (compose); `-e MSG` passes the text without shell-quoting hazards.

- [ ] **Step 2: Register + schedule**

```bash
docker exec homeai-postgres psql -U postgres -d homeai -c \
 "INSERT INTO ops.pipeline_registry(name,kind,script_path,schedule_cron,freshness_sql,freshness_sla_hours,notes)
  VALUES ('ops_digest','report','scripts/u-ops-digest.sh','45 7 * * *',
          'SELECT max(finished_at) FROM ops.pipeline_runs WHERE name=''ops_digest'' AND status=''ok''',26,
          'R0.4 daily Telegram ops digest') ON CONFLICT (name) DO NOTHING;"
# add the cron line to scripts/crontab.canonical.txt, then:
bash scripts/install-crontab.sh
```

- [ ] **Step 3: Run manually and verify on Telegram**

```bash
bash /home_ai/scripts/u-ops-digest.sh
```
Expected: `sent: True`; Jo receives the digest listing current stale/firing/open items (there are real ones today — hermes-sentinel CronStale at minimum).

- [ ] **Step 4: Commit**

```bash
cd /home_ai && git add scripts/u-ops-digest.sh scripts/crontab.canonical.txt && git commit -m "feat(ops): R0.4 daily Telegram ops digest (stale pipelines + firing alerts + open exceptions)"
```

---

### Task 5: Deep health probes (ollama generate-probe + full-fleet selftest)

**Files:**
- Modify: `scripts/u241-supervisor.sh` (ollama check upgraded from `ollama --version` to a 1-token generation)
- Modify: `scripts/selftest.sh` §1 (probe every compose container, not 11)

**Interfaces:**
- Consumes: ollama `/api/generate`; `docker ps` vs compose container_name list.
- Produces: supervisor treats "alive but cannot generate within 60s" as an ollama failure (existing restart path E fires); selftest fails if ANY compose-defined container is not running.

- [ ] **Step 1: Add the generate-probe to u241-supervisor.sh**

Locate the health-check section that currently only pings containers (the `FAILS` builder). Add after ollama's liveness check:
```bash
# Deep probe: a wedged ollama answers /api/version but 503s generation for days
# (2026-06-30..07-02 outage). 1-token probe, 60s budget.
if docker exec homeai-ollama ollama --version >/dev/null 2>&1; then
  OLLAMA_GEN=$(curl -s -m 60 -o /dev/null -w '%{http_code}' http://127.0.0.1:11434/api/generate \
    -d '{"model":"qwen2.5:7b","prompt":"ok","stream":false,"options":{"num_predict":1}}' || echo 000)
  if [ "$OLLAMA_GEN" != "200" ]; then
    FAILS="${FAILS}\nollama: generate-probe failed (http $OLLAMA_GEN)"
  fi
fi
```
(Adjust variable names to match the script's actual FAILS accumulation on reading it — the restart branch already matches `grep -qiE 'ollama'` on `$FAILS`.)

- [ ] **Step 2: Verify the probe path**

```bash
bash /home_ai/scripts/u241-supervisor.sh; echo "rc=$?"
```
Expected: normal run, no ollama repair triggered (it is healthy). Then simulate: `docker pause homeai-ollama; bash scripts/u241-supervisor.sh; docker unpause homeai-ollama` — expected: supervisor detects and attempts the ollama repair path (check its log), unpause restores.

- [ ] **Step 3: Full-fleet selftest**

Replace the 11 hard-coded `check "homeai-X" "running homeai-X"` lines in `scripts/selftest.sh` §1 with:
```bash
for c in $(grep -oE 'container_name: (homeai-[a-z0-9-]+)' /home_ai/docker-compose.yml | awk '{print $2}' | sort -u); do
  check "$c" "running $c"
done
```
Run `bash scripts/selftest.sh` — expected: §1 lists ~33 containers, all PASS today (fleet verified up at 18:05). Note: `garmin-service`/`vault-mcp` are compose-defined but never created — if they FAIL, remove those service stanzas (they are dead config, spec R5.3) or add them to an explicit skip list with a comment.

- [ ] **Step 4: Commit**

```bash
cd /home_ai && git add scripts/u241-supervisor.sh scripts/selftest.sh && git commit -m "feat(ops): R0.5 deep ollama generate-probe + full-fleet selftest coverage"
```

---

### Task 6: Boot-race recovery for every tailnet-bound service

**Files:**
- Create: `scripts/recreate-with-secrets.sh` (formalise the proven 2026-07-02 recovery script)
- Create: `scripts/u273b-boot-recreate.sh`
- Modify: `scripts/crontab.canonical.txt` (add `@reboot bash /home_ai/scripts/u273b-boot-recreate.sh >> /home_ai/logs/u273b-boot.log 2>&1`) + reinstall

**Interfaces:**
- Consumes: `.env` VAULT_TOKEN; Vault secrets (same set as start.sh fetch_secrets); compose port map.
- Produces: `recreate-with-secrets.sh <service>...` — harvests secrets then `docker compose up -d --force-recreate --no-deps "$@"`; u273b waits for the tailnet IP, then curl-probes every `100.104.82.53:<port>` publish and recreates the owning service for any dead port.

- [ ] **Step 1: Commit the proven harvest+recreate script**

Copy the working script from the 2026-07-02 session (content below) to `scripts/recreate-with-secrets.sh`, `chmod 750`:
```bash
#!/usr/bin/env bash
# recreate-with-secrets.sh <compose-service>... — force-recreate services with
# the same secret harvest start.sh performs. Non-interactive: requires vault
# unsealed + VAULT_TOKEN in /home_ai/.env. Proven 2026-07-02 (8 boot-race victims).
set -euo pipefail
umask 077
cd /home_ai
set -a; . ./.env; set +a
[[ -n "${VAULT_TOKEN:-}" ]] || { echo "no VAULT_TOKEN in .env" >&2; exit 1; }
vkf() { docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault \
        vault kv get -format=json "$1" 2>/dev/null | jq -er ".data.data.\"$2\""; }
POSTGRES_PASSWORD=$(vkf secret/postgres password)
REDIS_PASSWORD=$(vkf secret/redis password)
GRAFANA_ADMIN_PASSWORD=$(vkf secret/grafana admin_password)
OPEN_WEBUI_SECRET=$(vkf secret/open-webui secret_key)
PAYLOAD_HMAC_KEY=$(vkf secret/signing payload_hmac_key)
ANTHROPIC_API_KEY=$(vkf secret/anthropic api_key)
ROLES_JSON=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault vault kv get -format=json secret/postgres-roles)
N8N_DB_PASSWORD=$(jq -er '.data.data.homeai_pipeline' <<<"$ROLES_JSON")
METABASE_APP_PASSWORD=$(jq -er '.data.data.metabase_app' <<<"$ROLES_JSON" || echo "")
PAPERLESS_DB_PASSWORD=$(jq -er '.data.data.paperless' <<<"$ROLES_JSON" || echo "")
ROLES_JSON=""
BREAKFAST_TOKEN_SECRET=$(vkf secret/breakfast token_secret || echo "")
export POSTGRES_PASSWORD REDIS_PASSWORD GRAFANA_ADMIN_PASSWORD OPEN_WEBUI_SECRET \
       PAYLOAD_HMAC_KEY ANTHROPIC_API_KEY N8N_DB_PASSWORD METABASE_APP_PASSWORD \
       PAPERLESS_DB_PASSWORD BREAKFAST_TOKEN_SECRET
echo "secrets harvested; recreating: $*"
docker compose up -d --force-recreate --no-deps "$@"
```

- [ ] **Step 2: Write the boot sweeper**

`scripts/u273b-boot-recreate.sh`:
```bash
#!/usr/bin/env bash
# u273b — after reboot, wait for the tailnet IP then heal every tailnet-bound
# port publish. Complements u273 (Caddy-only). Runs @reboot; idempotent.
set -euo pipefail
echo "START $(date -Is)"
for i in $(seq 1 60); do
  ip -4 addr show tailscale0 2>/dev/null | grep -q '100.104.82.53' && break; sleep 5
done
ip -4 addr show tailscale0 | grep -q '100.104.82.53' || { echo "tailnet IP never arrived"; exit 1; }
sleep 20   # let compose restart-policies finish their own attempts first

declare -A OWNER   # host-port -> compose service key
while read -r svc port; do OWNER[$port]=$svc; done <<'MAP'
grafana 3001
authelia 9091
open-webui 8088
llm-router 8001
homeai-data-proxy 8771
wa-bridge 8770
homeai-mcp 8765
paperless 8011
ollama 11434
MAP
# Caddy (80/443/5678/3000) is u273's job.

DEAD=()
for port in "${!OWNER[@]}"; do
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://100.104.82.53:${port}/" || echo 000)
  [ "$code" = "000" ] && DEAD+=("${OWNER[$port]}")
done
if [ "${#DEAD[@]}" -eq 0 ]; then echo "all publishes alive"; exit 0; fi
echo "dead publishes -> recreating: ${DEAD[*]}"
bash /home_ai/scripts/recreate-with-secrets.sh "${DEAD[@]}"
sleep 15
for port in "${!OWNER[@]}"; do
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://100.104.82.53:${port}/" || echo 000)
  echo "post-heal port $port -> $code"
done
echo "DONE $(date -Is)"
```

- [ ] **Step 3: Dry-verify without a reboot**

```bash
bash /home_ai/scripts/u273b-boot-recreate.sh
```
Expected: "all publishes alive" (fleet is healthy). Then prove the heal path on one low-risk service: `docker rm -f homeai-grafana && bash scripts/u273b-boot-recreate.sh` — expected: grafana recreated, `post-heal port 3001 -> 301`.

- [ ] **Step 4: Add @reboot line + commit**

```bash
# append to scripts/crontab.canonical.txt:
#   @reboot bash /home_ai/scripts/u273b-boot-recreate.sh >> /home_ai/logs/u273b-boot.log 2>&1
cd /home_ai && bash scripts/install-crontab.sh
git add scripts/recreate-with-secrets.sh scripts/u273b-boot-recreate.sh scripts/crontab.canonical.txt
git commit -m "feat(ops): R0.6 boot-race self-heal for all tailnet-bound services"
```

---

### Task 7: Schedule the auditor

**Files:**
- Modify: `scripts/crontab.canonical.txt` (add auditor line) + reinstall
- Registry row: seeded in Task 1 (`system_auditor`).

**Interfaces:**
- Consumes: `PYTHONPATH=/home_ai python3 scripts/u-system-auditor.py` (verified working invocation; `--dry-run` skips DB writes of findings but still heartbeats).
- Produces: nightly rows in `cognition.agent_findings` (agent='auditor') + `ops.pipeline_runs('system_auditor', ...)`.

- [ ] **Step 1: Manual write-mode run**

```bash
cd /home_ai && PYTHONPATH=/home_ai python3 scripts/u-system-auditor.py 2>&1 | tail -20
docker exec homeai-postgres psql -U postgres -d homeai -tAc \
 "SELECT count(*) FROM cognition.agent_findings WHERE created_at > now()-interval '10 min';
  SELECT status, note FROM ops.pipeline_runs WHERE name='system_auditor' ORDER BY finished_at DESC LIMIT 1"
```
Expected: findings rows > 0 (there is real drift to find), heartbeat row present (registry FK satisfied by V279). If the digest-delivery step of the auditor errors, capture the traceback — Tasks 9/10 of the auditor's own plan were unfinished; fix only what blocks the nightly run, defer digest polish to its own plan.

- [ ] **Step 2: Add the cron line**

```
30 5 * * * cd /home_ai && bash scripts/ops-run.sh system_auditor -- env PYTHONPATH=/home_ai python3 scripts/u-system-auditor.py >> /home_ai/logs/system-auditor.log 2>&1
```
(Note: the auditor self-heartbeats too — ops-run's wrapper row is harmless duplication; keep the wrapper for failure capture.)

- [ ] **Step 3: Install + commit**

```bash
cd /home_ai && bash scripts/install-crontab.sh
git add scripts/crontab.canonical.txt && git commit -m "feat(ops): R0.7 schedule nightly system auditor (05:30)"
```

---

### Task 8: Generic partition maintenance

**Files:**
- Create: `postgres/migrations/V280__ops_ensure_partitions.sql`
- Modify: `scripts/crontab.canonical.txt` (partition-maintenance line swaps function)

**Interfaces:**
- Consumes: `pg_partitioned_table`/`pg_inherits` catalogs.
- Produces: `ops.ensure_partitions()` returns `(parent text, partition_name text, was_created boolean)`; creates next-month + month-after RANGE partitions and a DEFAULT `<table>_overflow` for EVERY partitioned parent (the 2026-07-02 incident: 10 parents had no July partition).

- [ ] **Step 1: Write the migration**

```sql
-- V280: generic partition maintenance (replaces events-only ensure_next_event_partition)
CREATE OR REPLACE FUNCTION ops.ensure_partitions()
RETURNS TABLE(parent text, partition_name text, was_created boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE p RECORD; m DATE; pname TEXT; existed BOOLEAN;
BEGIN
  FOR p IN SELECT ns.nspname AS sch, c.relname AS tbl
           FROM pg_partitioned_table pt
           JOIN pg_class c ON c.oid = pt.partrelid
           JOIN pg_namespace ns ON ns.oid = c.relnamespace LOOP
    FOR m IN SELECT generate_series(date_trunc('month', now())::date,
                                    date_trunc('month', now() + interval '2 months')::date,
                                    interval '1 month')::date LOOP
      pname := p.tbl || '_' || to_char(m, 'YYYY_MM');
      existed := EXISTS (SELECT 1 FROM pg_class pc JOIN pg_namespace pn ON pn.oid=pc.relnamespace
                         WHERE pc.relname=pname AND pn.nspname=p.sch);
      IF NOT existed THEN
        EXECUTE format('CREATE TABLE %I.%I PARTITION OF %I.%I FOR VALUES FROM (%L) TO (%L)',
                       p.sch, pname, p.sch, p.tbl, m, m + interval '1 month');
      END IF;
      parent := p.sch||'.'||p.tbl; partition_name := pname; was_created := NOT existed; RETURN NEXT;
    END LOOP;
    pname := p.tbl || '_overflow';
    existed := EXISTS (SELECT 1 FROM pg_class pc JOIN pg_namespace pn ON pn.oid=pc.relnamespace
                       WHERE pc.relname=pname AND pn.nspname=p.sch);
    IF NOT existed THEN
      EXECUTE format('CREATE TABLE %I.%I PARTITION OF %I.%I DEFAULT', p.sch, pname, p.sch, p.tbl);
    END IF;
    parent := p.sch||'.'||p.tbl; partition_name := pname; was_created := NOT existed; RETURN NEXT;
  END LOOP;
END $$;
```

- [ ] **Step 2: Apply + test idempotency**

```bash
docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 < /home_ai/postgres/migrations/V280__ops_ensure_partitions.sql
docker exec homeai-postgres psql -U postgres -d homeai -tAc \
 "SELECT count(*) FILTER (WHERE was_created), count(*) FROM ops.ensure_partitions()"
```
Expected first run: `0|N` or few created (Jun–Aug already exist from the 07-02 triage; September gets created when now()+2mo crosses). Run twice — second run MUST report 0 created (idempotent).

- [ ] **Step 3: Swap the cron line**

Replace the `30 3 25 * *` line in `scripts/crontab.canonical.txt` with:
```
30 3 25 * * docker exec homeai-postgres psql -U postgres -d homeai -c "SELECT ops.record_pipeline_run('partition_maintenance','ok',now(),(SELECT count(*)::int FROM ops.ensure_partitions() WHERE was_created),'generic ensure_partitions');" >> /home_ai/logs/partition-maintenance.log 2>&1
```
Install: `bash scripts/install-crontab.sh`.

- [ ] **Step 4: Commit**

```bash
cd /home_ai && git add postgres/migrations/V280__ops_ensure_partitions.sql scripts/crontab.canonical.txt
git commit -m "feat(db): R0.8 generic partition maintenance for all partitioned parents"
```

---

### Task 9: `set -e` sweep (143 scripts, batched)

**Files:**
- Modify: every `scripts/*.sh` matching `set -uo pipefail` without `-e` (list generated in Step 1), in 4 batches.
- Exclusions (intentional non-fatal designs — do NOT change): `scripts/ops-run.sh`, `scripts/u241-supervisor.sh`, `scripts/u272-dashboard-watchdog.sh`, `scripts/u273-caddy-boot.sh` (watchdogs must not die mid-repair; they handle errors internally).

**Interfaces:** none — behavioural hardening only. After this task, a failing inner psql/curl aborts the script → ops-run records `failed` → digest surfaces it.

- [ ] **Step 1: Generate the worklist**

```bash
cd /home_ai && grep -rlE '^set -uo pipefail' scripts/ --include='*.sh' \
  | grep -vE 'ops-run.sh|u241-supervisor.sh|u272-dashboard-watchdog.sh|u273-caddy-boot.sh' \
  | sort > /tmp/setE-worklist.txt
wc -l /tmp/setE-worklist.txt
```
Expected: ~140 files.

- [ ] **Step 2–5: For each batch of ~35 files (alphabetical quarters):**

Per file, in this order:
1. `sed -i 's/^set -uo pipefail/set -euo pipefail/' <file>`
2. Read the diff context: any command that may legitimately fail mid-script (grep with no matches, curl to an optional service, `docker exec` probes, arithmetic on possibly-empty vars, `read -r` from command substitution) gets an explicit `|| true` / `|| echo 0` guard. Specifically audit: `grep -c` (exits 1 on zero matches!), `[ ]`-less `(( ))` arithmetic (exits 1 when result is 0), and any `$(...)` whose failure should degrade rather than abort.
3. `bash -n <file>` (syntax check) — expected: silence.
4. If the script has a safe read-only mode (e.g. takes a limit arg, or is a pure reporter), run it once and compare output with its last log entry.

Then commit the batch:
```bash
git add scripts/ && git commit -m "fix(scripts): R0.9 batch <n>/4 — set -e on silent-exit-0 scripts (with || true audit)"
```

- [ ] **Step 6: Next-morning verification**

After 24h: `docker exec homeai-postgres psql -U postgres -d homeai -tAc "SELECT name, status, note FROM ops.pipeline_runs WHERE status='failed' AND finished_at > now()-interval '24 hours'"` and `tail -50 /home_ai/logs/cron-health-check.log`. Expected: any newly-failing script is a REAL failure that was silent before (fix forward), not an over-eager `-e` (add the missing guard). Budget one follow-up commit for guards.

---

## Self-review notes

- Spec §3 coverage: item 1→Task 1, 2→Task 4, 3→Task 3, 4→Task 7, 5→Task 5, 6→Task 6, 7→Task 9, 8→Task 8, 9→Task 2. All nine covered.
- Task 1's generator is the single source for crontab + seed; Tasks 4/6/7/8 append to the canonical file — the generator's `--check` mode will flag drift, so those tasks edit the committed file (not regenerate). If gen-canonical-crontab.py is re-run later it must be taught the new lines first (acceptable: the generator is a one-shot migration tool; the canonical file is the ongoing truth).
- The `weather_sync` keep-variant decision (stdin form) contradicts TD-037's suggestion deliberately: the host-file form survives container recreation; the `-i` trap only bites inside while-read loops, which crontab lines are not.
