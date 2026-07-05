#!/usr/bin/env python3
"""Generate the canonical heartbeat-wrapped crontab + registry seed from the
live crontab. Deterministic; run with --check to diff against committed output.
Policy:
  - DEDUPE: for each key in DUPE_KEEP, keep exactly the listed line-substring
    variant, drop other lines whose command contains the key.
  - EXCLUDE (not wrapped, kept verbatim): every-minute jobs (cron-health covers
    liveness), @reboot, rsync mirror, docker prune, gpu sampler, snag-trigger.
  - DEVNULL FIX (fix, see task-1-report.md): a trailing `>/dev/null [2>&1]`
    would silently swallow ops-run.sh's passthrough output entirely; those
    jobs get redirected into a per-job log file instead.
  - COMPOUND GUARD (fix, see task-1-report.md): if the extracted core command
    contains a top-level shell control operator (&&, ;, bare |) OUTSIDE the
    trailing redirect, ops-run.sh's `"$@"` exec cannot wrap it safely — cron
    invokes the whole generated line via `sh -c`, so those operators split the
    line into separate top-level commands and only the first fragment (often
    just `set -a` or a bare `cp`) ends up wrapped/heartbeated; worse, on lines
    chained with `&&` a non-zero *wrapper* exit can short-circuit the real
    script and it never runs at all. Those lines are kept UNWRAPPED verbatim
    (WARN'd) instead of guessing a rewrite.
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
    "u58-bank-tx-categorise.sh": "bank_tx_categorise",
    # FIX (see task-1-report.md): existing registry row for this script is named
    # 'revenue_recon' (not 'revenue_recon_check'); reuse it so ON CONFLICT(name)
    # lands on the existing row instead of minting a second registry entry for
    # the same script under a different name.
    "u-revenue-recon-check.sh": "revenue_recon", "u62-tanda-sync.sh": "tanda_sync",
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
        # FIX (see task-1-report.md, Step 3e): a bare `>/dev/null [2>&1]` tail
        # discards ops-run.sh's passthrough entirely — cron-health then can't
        # tell "ran fine" from "silently never ran". Redirect into a real
        # per-job log instead of leaving it to /dev/null.
        if re.search(r">\s*/dev/null(\s+2>&1)?\s*$", cmd):
            cmd = re.sub(r">\s*/dev/null(\s+2>&1)?\s*$", f">> /home_ai/logs/{name}.cron.log 2>&1", cmd)
        # split trailing log redirection so ops-run passthrough still reaches the log
        m = re.match(r"(.*?)(\s*(?:>>|2>&1|\|\s*tee).*)$", cmd)
        core, redir = (m.group(1).strip(), m.group(2)) if m else (cmd, "")
        core = re.sub(r"^cd /home_ai && ", "", core)
        # FIX (see task-1-report.md): a top-level &&, ; or bare | left in `core`
        # means cron's `sh -c` will split the generated line into separate
        # commands, so ops-run.sh only ever wraps the first fragment (and on
        # `&&` chains a non-zero wrapper exit can stop the real script running
        # at all). Caught this on u160-breakfast-send.py / breakfast-kitchen.py
        # (env-sourcing chain) and u128-xero-parse.sh (cp ...; parse ...).
        # Keep those lines unwrapped rather than guessing a safe rewrite.
        if re.search(r"(?:\s&&\s|;|\s\|\s(?!tee))", core):
            print(f"WARN: compound top-level command, kept unwrapped: {s}", file=sys.stderr)
            out_lines.append(s); continue
        out_lines.append(f"{schedule} cd /home_ai && bash scripts/ops-run.sh {name} -- {core}{redir}")
        sla = cadence_hours(schedule)
        seed.append((name, "sweep", base, schedule, sla))

    canonical = "\n".join(out_lines) + "\n"
    # Registry seed is written to a NON-migration helper file. It used to
    # rewrite postgres/migrations/V279__... — regenerating an APPLIED
    # migration from the live crontab clobbered its seed history the moment
    # parsing drifted (nearly reduced V279 to 2 rows, U294 T4 2026-07-05).
    # Migrations are immutable; this helper is idempotent (ON CONFLICT DO
    # NOTHING) and safe to apply any time a new wrapped entry appears.
    seed_sql = ["-- pipeline_registry seed for canonical crontab entries",
                "-- (generated by gen-canonical-crontab.py; idempotent; NOT a migration)"]
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

    ct = pathlib.Path("scripts/crontab.canonical.txt")
    seedf = pathlib.Path("scripts/crontab.registry-seed.sql")
    if check:
        ok = ct.read_text() == canonical and (seedf.exists() and seedf.read_text() == sql)
        print("CHECK", "PASS" if ok else "FAIL"); sys.exit(0 if ok else 1)
    ct.write_text(canonical); seedf.write_text(sql)
    print(f"wrote {ct} ({len(out_lines)} lines) and {seedf} ({len(seed)+1} seed rows)")
    print("apply seed (idempotent): docker exec -i homeai-postgres psql -U postgres -d homeai -f - < scripts/crontab.registry-seed.sql")

if __name__ == "__main__":
    main()
