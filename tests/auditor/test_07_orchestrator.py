# tests/auditor/test_07_orchestrator.py
import importlib.util
import pathlib

spec = importlib.util.spec_from_file_location(
    "auditor_main", pathlib.Path("scripts/u-system-auditor.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def test_run_collects_all_checks_dryrun():
    findings = m.run(write=False, llm=False)
    ids = {f.check_id for f in findings}
    assert {'events_overflow', 'invariants', 'taxonomy_vocabulary'} <= ids
    assert len(findings) >= 11  # 8 integrity + >=3 architecture
    for f in findings:
        assert f.severity in ('ok', 'info', 'warn', 'fail')


def test_one_bad_check_does_not_abort():
    def boom():
        raise RuntimeError("nope")
    findings = m.run(write=False, llm=False, extra_checks=[boom])
    assert any(f.check_id == 'boom' and f.severity == 'fail' for f in findings)
