from .finding import Finding, psql


def _q(s: str) -> str:
    return s.replace("'", "''")


def persist(findings):
    for f in findings:
        psql(f"""
          INSERT INTO cognition.agent_findings
            (agent, kind, subject, detail, verified, evidence, realm,
             severity, status, fingerprint, created_at, last_seen_at)
          VALUES ('system-auditor', 'finding', '{_q(f.title)}', '{_q(f.detail)}',
                  true, '{_q(f.value)}', 'owner', '{f.severity}', '{f.status}',
                  '{f.fingerprint}', now(), now())
          ON CONFLICT (fingerprint) WHERE fingerprint IS NOT NULL DO UPDATE SET
            subject=EXCLUDED.subject, detail=EXCLUDED.detail, evidence=EXCLUDED.evidence,
            severity=EXCLUDED.severity, status=EXCLUDED.status, last_seen_at=now();
        """)


def resolve_stale(seen_check_ids):
    seen = ",".join("'auditor_" + _q(c) + "'" for c in seen_check_ids) or "''"
    psql(f"""UPDATE cognition.agent_findings SET status='resolved', last_seen_at=now()
             WHERE agent='system-auditor' AND status='firing'
               AND fingerprint NOT IN ({seen});""")
