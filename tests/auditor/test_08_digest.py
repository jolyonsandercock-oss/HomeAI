# tests/auditor/test_08_digest.py
from scripts.auditor.finding import Finding
from scripts.auditor.digest import plain_digest


def test_plain_digest_sorted_and_safe():
    # NB: corrected vs plan draft — plain_digest excludes ok-severity findings
    # (the morning brief surfaces problems only; the all-green branch proves intent).
    # So ordering is asserted between two non-ok severities.
    fs = [Finding('a', 'integrity', 'warn', 'Warn thing', 'meh'),
          Finding('b', 'architecture', 'fail', 'Bad thing', 'broken'),
          Finding('c', 'integrity', 'ok', 'OK thing', 'fine')]
    out = plain_digest(fs)
    assert 'Bad thing' in out
    assert out.index('Bad thing') < out.index('Warn thing')  # fail before warn
    assert 'OK thing' not in out  # ok excluded from the brief
    assert '<' in out  # html


def test_plain_digest_all_green():
    out = plain_digest([Finding('a', 'integrity', 'ok', 'OK', 'fine')])
    assert 'green' in out.lower()
