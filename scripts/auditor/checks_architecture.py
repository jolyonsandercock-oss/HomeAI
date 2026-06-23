# scripts/auditor/checks_architecture.py
# Architecture lens ('how'): information-architecture / structural drift.
# Each callable -> Finding. Verified against live DB + repo 2026-06-23.
import subprocess
import re
import os
from .finding import Finding, psql, psql_scalar

REPO = '/home_ai'
CANON_DEPTS = {'bar', 'kitchen', 'cafe', 'rooms', 'overhead'}


def check_invariants():
    r = subprocess.run(['python3', f'{REPO}/scripts/audit-invariants.py', '--check'],
                       capture_output=True, text=True, cwd=REPO)
    # --check exits 1 ONLY on a NEW FAIL vs .audit-baseline.txt (pre-push gate contract);
    # 0 otherwise (clean, or new WARN-only). See audit-invariants.py:465-477.
    new = r.returncode != 0
    sev = 'fail' if new else 'ok'
    detail = 'NEW invariant violation vs baseline' if new else 'no new invariant findings (baseline clean)'
    return Finding('invariants', 'architecture', sev, 'Invariant gate', detail,
                   (r.stdout or r.stderr).strip()[:200])


def check_taxonomy_vocabulary():
    rows = psql(f"""select category_canonical, count(*) from vendor_invoice_inbox
                    where category_canonical is not null
                      and lower(category_canonical) not in ({','.join("'"+d+"'" for d in CANON_DEPTS)})
                    group by 1 order by 2 desc limit 10""")
    n = len(rows)
    vocab = ', '.join(f'{r[0]}({r[1]})' for r in rows) if rows else 'none'
    return Finding('taxonomy_vocabulary', 'architecture', 'warn' if n else 'ok',
                   'Out-of-vocabulary categories',
                   f'{n} category value(s) outside {sorted(CANON_DEPTS)}: {vocab}', str(n))


def check_untracked_load_bearing():
    tracked = set(subprocess.run(['git', 'ls-files'], cwd=REPO, capture_output=True, text=True).stdout.split())
    crontab = subprocess.run(['crontab', '-l'], capture_output=True, text=True).stdout
    referenced = set(re.findall(r'/home_ai/(scripts/[\w./-]+\.(?:sh|py))', crontab))
    missing = sorted(p for p in referenced if p not in tracked and os.path.exists(f'{REPO}/{p}'))
    return Finding('untracked_load_bearing', 'architecture', 'warn' if missing else 'ok',
                   'Untracked load-bearing files',
                   f'{len(missing)} cron-referenced file(s) not in git: {", ".join(missing[:5]) or "none"}',
                   str(len(missing)))


def check_realm_coverage():
    # Best-effort v1: count rows with NULL realm in the canonical realm-scoped tables.
    nulls = int(psql_scalar("""select coalesce(sum(c),0) from (
                  select count(*) c from vendor_invoice_inbox where realm is null
                  union all select count(*) from bank_transactions where realm is null) x""") or 0)
    return Finding('realm_coverage', 'architecture', 'warn' if nulls else 'ok',
                   'Realm coverage', f'{nulls} row(s) missing realm in invoice/bank tables', str(nulls))


def check_guc_drift():
    # The SET-ROLE-drops-GUC-defaults gotcha: the entity GUC default must exist on the role.
    n = int(psql_scalar("""select count(*) from pg_db_role_setting s
                           join pg_roles r on r.oid=s.setrole
                           where r.rolname='hermes_ro'
                             and array_to_string(s.setconfig,',') ~ 'app.current_entity'""") or 0)
    return Finding('guc_drift', 'architecture', 'warn' if n == 0 else 'ok',
                   'RLS GUC defaults', 'hermes_ro entity GUC default present' if n else
                   'hermes_ro missing app.current_entity default (RLS may return 0 rows)', str(n))


def check_n8n_cron_reconciliation():
    # Meta-risk: runners (n8n active + cron) with no pipeline_registry entry.
    try:
        reg = int(psql_scalar("select count(*) from ops.pipeline_registry where enabled") or 0)
        runs = int(psql_scalar("select count(*) from ops.pipeline_runs where finished_at > now()-interval '48 hours'") or 0)
    except RuntimeError:
        return Finding('n8n_cron_reconciliation', 'architecture', 'info',
                       'n8n/cron reconciliation', 'pipeline registry unavailable', 'n/a')
    gap = reg == 0
    return Finding('n8n_cron_reconciliation', 'architecture', 'warn' if gap else 'info',
                   'n8n/cron reconciliation',
                   f'{reg} registered pipelines, {runs} runs in 48h'
                   + (' — registry EMPTY (drift unmeasured)' if gap else ''), f'{reg}/{runs}')


ARCHITECTURE_CHECKS = [check_invariants, check_taxonomy_vocabulary, check_untracked_load_bearing]
ARCHITECTURE_CHECKS += [check_realm_coverage, check_guc_drift, check_n8n_cron_reconciliation]
