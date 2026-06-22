import subprocess
from dataclasses import dataclass

SEVERITIES = ('ok', 'info', 'warn', 'fail')


@dataclass
class Finding:
    check_id: str
    lens: str          # 'integrity' | 'architecture'
    severity: str      # ok | info | warn | fail
    title: str
    detail: str
    value: str = ''

    @property
    def fingerprint(self) -> str:
        return 'auditor_' + self.check_id

    @property
    def status(self) -> str:
        return 'firing' if self.severity in ('warn', 'fail') else 'resolved'


def psql(sql: str):
    """Run SQL in homeai-postgres; return rows as list[list[str]] (cols split on 0x1f)."""
    r = subprocess.run(
        ['docker', 'exec', 'homeai-postgres', 'psql', '-U', 'postgres', '-d', 'homeai',
         '-tAF', '\x1f', '-v', 'ON_ERROR_STOP=1', '-c', sql],
        capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip()[:300])
    return [ln.split('\x1f') for ln in r.stdout.splitlines() if ln]


def psql_scalar(sql: str):
    rows = psql(sql)
    return rows[0][0] if rows and rows[0] else None
