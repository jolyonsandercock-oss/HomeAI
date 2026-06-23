from scripts.auditor.finding import Finding, psql_scalar
from scripts.auditor.persist import persist, resolve_stale

def test_upsert_and_resolve():
    persist([Finding('selftest_x', 'integrity', 'fail', 'T', 'D', '1')])
    row = psql_scalar("select severity||'/'||status from cognition.agent_findings where fingerprint='auditor_selftest_x'")
    assert row == 'fail/firing'
    # re-run resolved
    persist([Finding('selftest_x', 'integrity', 'ok', 'T', 'D', '0')])
    assert psql_scalar("select status from cognition.agent_findings where fingerprint='auditor_selftest_x'") == 'resolved'
    # stale resolution
    resolve_stale([])  # nothing seen -> selftest_x already resolved; assert no firing auditor rows for it
    assert psql_scalar("select status from cognition.agent_findings where fingerprint='auditor_selftest_x'") == 'resolved'
    psql_scalar("delete from cognition.agent_findings where fingerprint='auditor_selftest_x'")  # cleanup
