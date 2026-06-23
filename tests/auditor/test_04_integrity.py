# tests/auditor/test_04_integrity.py
from scripts.auditor.checks_integrity import INTEGRITY_CHECKS


def test_all_return_findings():
    ids = set()
    for chk in INTEGRITY_CHECKS:
        f = chk()
        assert f.lens == 'integrity'
        assert f.severity in ('ok', 'info', 'warn', 'fail')
        assert f.title and f.check_id
        ids.add(f.check_id)
    assert 'events_overflow' in ids and 'invoice_categorisation' in ids
    assert len(ids) == len(INTEGRITY_CHECKS)
