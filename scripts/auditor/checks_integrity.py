# scripts/auditor/checks_integrity.py
# Integrity lens ('what'): data-correctness checks. Each callable -> Finding.
# Verified against live homeai DB 2026-06-23:
#   - recon view is ops.v_revenue_reconciliation (status: 'reconciled'|'DRIFT')
#   - ops.check_freshness() returns (name, newest, sla_hours, age_hours, status='ok'|'STALE')
#   - live_state()->'invoices' has no uncategorised_gbp key -> derive from source table
from .finding import Finding, psql_scalar

BANK_FRESHNESS_SLA_DAYS = 7
BANK_DEDUP_BASELINE = 5


def check_events_overflow():
    n = int(psql_scalar("select count(*) from events_overflow") or 0)
    return Finding('events_overflow', 'integrity', 'fail' if n else 'ok',
                   'Event partition overflow', f'{n} rows in events_overflow (must be 0)', str(n))


def check_dead_letters():
    n = int(psql_scalar("select count(*) from dead_letter where not resolved") or 0)
    return Finding('dead_letters', 'integrity', 'warn' if n else 'ok',
                   'Unresolved dead letters', f'{n} unresolved', str(n))


def check_bank_freshness():
    d = psql_scalar("select (current_date - max(transaction_date))::int from bank_transactions")
    days = int(d or 999)
    return Finding('bank_freshness', 'integrity', 'warn' if days > BANK_FRESHNESS_SLA_DAYS else 'ok',
                   'Bank data freshness', f'newest txn {days}d old (SLA {BANK_FRESHNESS_SLA_DAYS}d)', str(days))


def check_bank_dedup():
    n = int(psql_scalar("""select count(*) from (select bank_account_id,transaction_date,amount,description,count(*) c
                           from bank_transactions group by 1,2,3,4 having count(*)>1) d""") or 0)
    return Finding('bank_dedup', 'integrity', 'warn' if n > BANK_DEDUP_BASELINE else 'ok',
                   'Bank exact-duplicate rows', f'{n} dup groups (baseline {BANK_DEDUP_BASELINE})', str(n))


def check_invoice_categorisation():
    pct = float(psql_scalar(
        "select ops.live_state()->'invoices'->>'categorisation_coverage_pct'") or 0)
    return Finding('invoice_categorisation', 'integrity', 'warn' if pct < 60 else 'info',
                   'Invoice categorisation coverage', f'{pct}% categorised', str(pct))


def check_invoice_uncategorised_gbp():
    # No live_state key exists for this; derive from source. Mirrors the coverage
    # denominator (is_statement=false, real statuses) but sums gross of uncategorised YTD.
    gbp = psql_scalar("""select coalesce(sum(gross_amount),0)::numeric(12,2)
                         from vendor_invoice_inbox
                         where is_statement=false
                           and status not in ('duplicate','ignored')
                           and category_canonical is null
                           and invoice_date >= date_trunc('year', current_date)""") or '0'
    return Finding('invoice_uncategorised_gbp', 'integrity', 'info',
                   'Uncategorised invoice value YTD', f'£{gbp} uncategorised this year', str(gbp))


def check_revenue_reconciliation():
    bad = int(psql_scalar("""select count(*) from ops.v_revenue_reconciliation
                             where status <> 'reconciled'""") or 0)
    return Finding('revenue_reconciliation', 'integrity', 'fail' if bad else 'ok',
                   'Revenue reconciliation', f'{bad} month(s) not reconciled', str(bad))


def check_pipeline_freshness():
    # ops.check_freshness() yields one row per pipeline; status is 'ok'|'STALE'.
    # Tolerate the function being absent on older schemas.
    try:
        n = int(psql_scalar("select count(*) from ops.check_freshness() where status <> 'ok'") or 0)
    except RuntimeError:
        return Finding('pipeline_freshness', 'integrity', 'info',
                       'Pipeline freshness', 'ops.check_freshness() unavailable', 'n/a')
    return Finding('pipeline_freshness', 'integrity', 'warn' if n else 'ok',
                   'Pipeline freshness', f'{n} pipeline(s) past SLA', str(n))


INTEGRITY_CHECKS = [
    check_revenue_reconciliation, check_bank_freshness, check_bank_dedup,
    check_invoice_categorisation, check_invoice_uncategorised_gbp,
    check_events_overflow, check_dead_letters, check_pipeline_freshness,
]
