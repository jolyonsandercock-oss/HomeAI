# scripts/auditor/digest.py
# Triage layer: deterministic HTML digest + optional LLM narrative on top.
# The LLM only re-phrases; it must introduce no number not in the findings (Spec §1).
import sys
from .finding import psql

_ORDER = {'fail': 0, 'warn': 1, 'info': 2, 'ok': 3}
_COLOUR = {'fail': '#b00020', 'warn': '#b26a00', 'info': '#444', 'ok': '#2e7d32'}


def plain_digest(findings) -> str:
    rows = sorted(findings, key=lambda f: _ORDER.get(f.severity, 9))
    lines = [f'<li style="color:{_COLOUR[f.severity]}"><b>[{f.severity.upper()}]</b> '
             f'{f.title} — {f.detail}</li>' for f in rows if f.severity != 'ok']
    if not lines:
        return '<p style="color:#2e7d32">All audit checks green.</p>'
    return '<ul>' + ''.join(lines) + '</ul>'


def build_digest(findings) -> str:
    findings_txt = "\n".join(
        f'[{f.severity}] {f.check_id}: {f.title} — {f.detail}' for f in findings)
    body = plain_digest(findings)
    try:
        sys.path.insert(0, '/home_ai')
        from lib import claude_call
        resp = claude_call.claude_messages({
            "model": "claude-haiku-4-5-20251001", "max_tokens": 350,
            "messages": [{"role": "user", "content":
                "You are a system auditor. Rank these findings by importance and write a 3-6 line "
                "plain-English summary for a daily ops brief. Use ONLY the facts below; introduce no "
                "new numbers. Findings:\n\n" + findings_txt}]})
        summary = resp["content"][0]["text"].strip()
        body = f'<p>{summary}</p>' + body
    except Exception:
        pass  # deterministic fallback already in `body`
    q = body.replace("'", "''")
    # kind='finding' (CHECK-constrained enum); the digest is identified by fingerprint='auditor_digest'.
    psql(f"""INSERT INTO cognition.agent_findings
             (agent, kind, subject, detail, verified, realm, severity, status, fingerprint, created_at, last_seen_at)
             VALUES ('system-auditor','finding','Daily audit digest','{q}',true,'owner','info','firing','auditor_digest',now(),now())
             ON CONFLICT (fingerprint) WHERE fingerprint IS NOT NULL DO UPDATE SET detail=EXCLUDED.detail, last_seen_at=now();""")
    return body
