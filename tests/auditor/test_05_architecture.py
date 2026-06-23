# tests/auditor/test_05_architecture.py
from scripts.auditor.checks_architecture import ARCHITECTURE_CHECKS


def test_all_return_findings():
    ids = {chk().check_id for chk in ARCHITECTURE_CHECKS}
    assert ids == {'invariants', 'taxonomy_vocabulary', 'untracked_load_bearing'}
    for chk in ARCHITECTURE_CHECKS:
        f = chk()
        assert f.lens == 'architecture' and f.severity in ('ok', 'info', 'warn', 'fail')
