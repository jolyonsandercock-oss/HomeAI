#!/usr/bin/env python3
"""u-system-auditor.py — nightly deterministic integrity+IA drift sweep.

Host-run (needs git/invariants/crontab). DB via docker exec psql. Cron ~05:30.
Heartbeats to stdout every run (cron-health silent-success rule).
Run from repo root: `cd /home_ai && python3 -m scripts.u-system-auditor`.
"""
import sys
import datetime
from scripts.auditor.finding import Finding, psql
from scripts.auditor.checks_integrity import INTEGRITY_CHECKS
from scripts.auditor.checks_architecture import ARCHITECTURE_CHECKS
from scripts.auditor.persist import persist, resolve_stale


def _safe(chk):
    try:
        return chk()
    except Exception as e:
        cid = getattr(chk, '__name__', 'unknown').replace('check_', '')
        return Finding(cid, 'integrity', 'fail', f'Check error: {cid}', str(e)[:200], 'error')


def run(write=True, llm=True, extra_checks=None):
    checks = list(INTEGRITY_CHECKS) + list(ARCHITECTURE_CHECKS) + list(extra_checks or [])
    findings = [_safe(c) for c in checks]
    if write:
        persist(findings)
        resolve_stale([f.check_id for f in findings])
        worst = 'fail' if any(f.severity == 'fail' for f in findings) else \
                'warn' if any(f.severity == 'warn' for f in findings) else 'ok'
        # record_pipeline_run(p_name, p_status, p_started, p_rows, p_note) — V269.
        # The run itself succeeded ('ok'); worst finding severity rides in the note.
        psql(f"SELECT ops.record_pipeline_run('system_auditor', 'ok', now(), NULL, '{worst}')")
    if llm:
        from scripts.auditor.digest import build_digest
        build_digest(findings)  # persists digest text; delivery handled by u109 (Task 9)
    return findings


if __name__ == '__main__':
    write = '--no-write' not in sys.argv
    llm = '--no-llm' not in sys.argv
    fs = run(write=write, llm=llm)
    n_fail = sum(f.severity == 'fail' for f in fs)
    n_warn = sum(f.severity == 'warn' for f in fs)
    print(f"{datetime.datetime.now().isoformat()} system-auditor heartbeat: "
          f"{len(fs)} checks, {n_fail} fail, {n_warn} warn")
