#!/usr/bin/env python3
"""u290-diagnostics-resolve-ok.py — make Diagnostics (daily) resolve cleared alerts.

The 'Eval + Build Alerts' code node only emitted alert payloads for
critical/warning test results — an 'ok' result emitted NOTHING, so a Diag_*
alert that fired once stayed status='firing' in system_alerts forever after
the condition cleared (observed: Diag_system_state stuck firing 2026-07-02
"global kill-switch" a full day after the supervisor auto-resumed;
Diag_dead_letter_recent/Diag_firing_alerts stuck since 2026-06-20).

Patch: also emit a status='resolved' payload for every 'ok' test. Safe by
design: alert-sink-v1 drops resolved-for-unknown-fingerprint (U235 T3), so
ok tests that never fired are no-ops at the sink.

Safety: writes a NEW workflow_history row + repoints activeVersionId
(editing workflow_entity.nodes does nothing — runtime reads history).
Rollback: UPDATE workflow_entity SET "activeVersionId"='<printed>' WHERE id='diagnostics-v1'
"""

import json
import subprocess
import sys
import uuid

WORKFLOW_ID = 'diagnostics-v1'
NODE_NAME = 'Eval + Build Alerts'
MARKER = 'u290: resolve-ok'

NEW_JS = r"""// Aggregate the run's results. Emit one alert payload per critical / warning,
// and a RESOLVED payload per ok test (u290: resolve-ok, 2026-07-03) — without
// these, a Diag_* alert that fired once stayed 'firing' forever after the
// condition cleared. alert-sink drops resolved-for-unknown-fingerprint
// (U235 T3), so ok tests that never fired are no-ops.
const rows = $input.all().map(i => i.json);
if (rows.length === 0) return [{ json: { skipped: true, reason: 'no diagnostic rows' } }];
const run_id = rows[0].run_id;

const critical = rows.filter(r => r.status === 'critical');
const warning  = rows.filter(r => r.status === 'warning');
const okrows   = rows.filter(r => r.status === 'ok');

const mk = (r, severity, kind) => ({
  fingerprint: 'diag_' + r.test_id,  // U250: stable — run_id suffix defeated the sink's fingerprint upsert
  alertname:   'Diag_' + r.test_id,
  severity,
  summary:     'diagnostic ' + kind + ': ' + r.test_id,
  description: r.detail || ''
});

const firing   = [...critical.map(r => mk(r, 'critical', 'critical')),
                  ...warning.map(r => mk(r, 'warning', 'warning'))];
const resolved = okrows.map(r => mk(r, 'info', 'ok'));
const now = new Date().toISOString();
const wrap = (a, status) => ({ ...a, status,
  startsAt: now, ...(status === 'resolved' ? { endsAt: now } : {}),
  labels: { alertname: a.alertname, severity: a.severity },
  annotations: { summary: a.summary, description: a.description } });

return [{
  json: {
    run_id,
    total: rows.length,
    ok:    okrows.length,
    warning: warning.length,
    critical: critical.length,
    alerts_json: JSON.stringify({ alerts: [
      ...firing.map(a => wrap(a, 'firing')),
      ...resolved.map(a => wrap(a, 'resolved'))
    ] })
  }
}];"""


def fetch_current():
    proc = subprocess.run(
        ['docker', 'exec', 'homeai-postgres', 'psql', '-U', 'postgres', '-d', 'homeai',
         '-tA', '-c', f"""SELECT row_to_json(t) FROM (
            SELECT "versionId" AS v, nodes::text AS nodes,
                   connections::text AS connections, name, authors
            FROM workflow_history
            WHERE "versionId" = (SELECT "activeVersionId" FROM workflow_entity WHERE id='{WORKFLOW_ID}')
         ) t;"""],
        check=True, capture_output=True, text=True,
    )
    data = json.loads(proc.stdout.strip())
    return {
        'current_version': data['v'],
        'nodes': json.loads(data['nodes']),
        'connections': json.loads(data['connections']),
        'name': data['name'],
        'authors': data['authors'],
    }


def patch_nodes(nodes):
    for n in nodes:
        if n.get('name') == NODE_NAME:
            params = n.setdefault('parameters', {})
            if MARKER in params.get('jsCode', ''):
                return False  # already patched
            params['jsCode'] = NEW_JS
            return True
    raise RuntimeError(f"{NODE_NAME!r} node not found in {WORKFLOW_ID}")


def install(current):
    new_uuid = str(uuid.uuid4())
    sql = f"""
BEGIN;
INSERT INTO workflow_history ("versionId", "workflowId", authors, nodes, connections, name, autosaved)
VALUES (
  '{new_uuid}',
  '{WORKFLOW_ID}',
  $authors${current['authors'] or 'u290'}$authors$,
  $nodes${json.dumps(current['nodes'])}$nodes$::json,
  $conns${json.dumps(current['connections'])}$conns$::json,
  $name${current['name']}$name$,
  false
);
UPDATE workflow_entity SET "activeVersionId"='{new_uuid}', "updatedAt"=NOW()
WHERE id='{WORKFLOW_ID}';
COMMIT;
"""
    subprocess.run(
        ['docker', 'exec', '-i', 'homeai-postgres', 'psql', '-U', 'postgres', '-d', 'homeai'],
        input=sql, check=True, capture_output=True, text=True,
    )
    print(f"patched. rollback: UPDATE workflow_entity SET \"activeVersionId\"='{current['current_version']}' WHERE id='{WORKFLOW_ID}';")


def main():
    current = fetch_current()
    if not patch_nodes(current['nodes']):
        print("already patched — no change")
        return
    install(current)


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as e:
        print(f'subprocess failed: {e}\nstderr: {e.stderr}', file=sys.stderr)
        sys.exit(1)
