#!/usr/bin/env python3
"""u228-wire-alert-sink-notify.py — insert a "Notify Bridge" HTTP node
into alert-sink-v1 between "Upsert system_alerts + audit" and
"Auto-Pause?". The Notify Bridge node POSTs a formatted message to the
notify-bridge webhook so Prometheus alerts actually page.

Safety: writes a NEW workflow_history row with a fresh UUID, repoints
workflow_entity.activeVersionId. Old version stays in history so we can
roll back instantly.

Continue-on-fail is set so notify-bridge being down (or vault being
sealed underneath it) does NOT block the rest of the alert-sink flow.
"""

import json
import subprocess
import sys
import uuid


WORKFLOW_ID = 'alert-sink-v1'
CURRENT_VERSION = '069a0254-755a-49c8-acd3-a754da6b1e77'

NOTIFY_NODE = {
    "id": "as-0007-notify-bridge",
    "name": "Notify Bridge",
    "type": "n8n-nodes-base.httpRequest",
    "position": [820, 300],
    "parameters": {
        "url": "http://homeai-n8n:5678/webhook/notify-bridge",
        "method": "POST",
        "options": {},
        "sendBody": True,
        "specifyBody": "json",
        "jsonBody": (
            "={{ JSON.stringify({ text: "
            "(($('Flatten Alerts').first().json.severity) === 'critical' ? '🔴 ' : "
            " ($('Flatten Alerts').first().json.severity) === 'warning' ? '🟡 ' : 'ℹ ')"
            "+ ($('Flatten Alerts').first().json.status === 'resolved' ? '<b>✓ Resolved:</b> ' : '<b>Firing:</b> ')"
            "+ ($('Flatten Alerts').first().json.alertname || 'unknown')"
            "+ '\\n' + ($('Flatten Alerts').first().json.summary || '')"
            "+ ($('Flatten Alerts').first().json.generator_url ? '\\n<a href=\"' + $('Flatten Alerts').first().json.generator_url + '\">grafana</a>' : '')"
            "}) }}"
        ),
        "contentType": "json",
    },
    "onError": "continueRegularOutput",
    "typeVersion": 4.2,
}


def fetch_current():
    proc = subprocess.run(
        ['docker', 'exec', 'homeai-postgres', 'psql', '-U', 'postgres', '-d', 'homeai',
         '-tA', '-c', f"""SELECT row_to_json(t) FROM (
            SELECT nodes::text AS nodes, connections::text AS connections,
                   name, authors FROM workflow_history WHERE "versionId"='{CURRENT_VERSION}'
         ) t;"""],
        check=True, capture_output=True, text=True,
    )
    data = json.loads(proc.stdout.strip())
    return {
        'nodes': json.loads(data['nodes']),
        'connections': json.loads(data['connections']),
        'name': data['name'],
        'authors': data['authors'],
    }


def patch(current):
    nodes = current['nodes']
    conns = current['connections']

    if any(n.get('name') == 'Notify Bridge' for n in nodes):
        print('Notify Bridge already present — nothing to do')
        return None

    for n in nodes:
        x, y = n['position']
        if n['name'] in ('Auto-Pause?',):
            n['position'] = [1040, y]
        elif n['name'] in ('Pause Pipelines', 'No Pause Needed'):
            n['position'] = [1260, y]

    nodes.append(NOTIFY_NODE)

    if 'Upsert system_alerts + audit' in conns:
        conns['Upsert system_alerts + audit'] = {
            'main': [[{'node': 'Notify Bridge', 'type': 'main', 'index': 0}]]
        }
    conns['Notify Bridge'] = {
        'main': [[{'node': 'Auto-Pause?', 'type': 'main', 'index': 0}]]
    }

    return {
        'nodes': nodes,
        'connections': conns,
        'name': current['name'],
        'authors': current['authors'],
    }


def install(patched):
    new_uuid = str(uuid.uuid4())
    sql = f"""
BEGIN;
INSERT INTO workflow_history ("versionId", "workflowId", authors, nodes, connections, name, autosaved)
VALUES (
  '{new_uuid}',
  '{WORKFLOW_ID}',
  $authors${patched['authors'] or 'u228'}$authors$,
  $nodes${json.dumps(patched['nodes'])}$nodes$::json,
  $conns${json.dumps(patched['connections'])}$conns$::json,
  $name${patched['name']}$name$,
  false
);
UPDATE workflow_entity SET "activeVersionId"='{new_uuid}', "updatedAt"=NOW()
WHERE id='{WORKFLOW_ID}';
SELECT 'new_version' AS k, "activeVersionId" AS v FROM workflow_entity WHERE id='{WORKFLOW_ID}';
COMMIT;
"""
    proc = subprocess.run(
        ['docker', 'exec', '-i', 'homeai-postgres', 'psql', '-U', 'postgres', '-d', 'homeai'],
        input=sql, check=True, capture_output=True, text=True,
    )
    print(proc.stdout)
    print(f'\n✓ patched. new versionId: {new_uuid}')
    print(f'  rollback: UPDATE workflow_entity SET "activeVersionId"=\'{CURRENT_VERSION}\' WHERE id=\'{WORKFLOW_ID}\';')


def main():
    current = fetch_current()
    patched = patch(current)
    if patched is None:
        return
    install(patched)


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as e:
        print(f'✗ subprocess failed: {e}\nstderr: {e.stderr}', file=sys.stderr)
        sys.exit(1)
