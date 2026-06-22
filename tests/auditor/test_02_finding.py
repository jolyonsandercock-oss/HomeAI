from scripts.auditor.finding import Finding, psql_scalar

def test_finding_fields():
    f = Finding('events_overflow', 'integrity', 'fail', 'Overflow', '3 rows', '3')
    assert f.fingerprint == 'auditor_events_overflow'
    assert f.status == 'firing'
    assert Finding('x','integrity','ok','t','d').status == 'resolved'

def test_psql_scalar_live():
    assert psql_scalar("select 1") == '1'
