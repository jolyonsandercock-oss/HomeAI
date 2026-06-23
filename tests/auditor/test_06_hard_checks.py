# tests/auditor/test_06_hard_checks.py
from scripts.auditor.checks_architecture import ARCHITECTURE_CHECKS


def test_hard_checks_present_and_safe():
    ids = {chk().check_id for chk in ARCHITECTURE_CHECKS}
    assert {'realm_coverage', 'guc_drift', 'n8n_cron_reconciliation'} <= ids
    for chk in ARCHITECTURE_CHECKS:
        f = chk()
        assert f.lens == 'architecture' and f.severity in ('ok', 'info', 'warn', 'fail')
