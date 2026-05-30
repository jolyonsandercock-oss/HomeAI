#!/usr/bin/env python3
"""u235-alert-sink-resolved-dedup.py — U235 T3.

Patch alert-sink-v1's "Upsert system_alerts + audit" node so that a
`status=resolved` arriving with no prior `firing` row for the same
fingerprint is dropped (no INSERT). Without this, every spurious
"resolved" message from Alertmanager creates a fresh resolved row,
adding noise to system_alerts.

Approach: rewrite the INSERT to use INSERT ... SELECT ... WHERE, with a
NOT EXISTS guard that filters out `resolved` for new fingerprints.

Safety: writes a NEW workflow_history row + repoints activeVersionId.
Rollback: UPDATE workflow_entity SET activeVersionId='<old>' WHERE id='alert-sink-v1'
"""

import json
import subprocess
import sys
import uuid

WORKFLOW_ID = 'alert-sink-v1'

# New SQL: INSERT ... SELECT with WHERE-NOT-EXISTS guard for resolved-with-no-fp.
NEW_SQL = """WITH inputs AS (
  SELECT
    '{{ $json.fingerprint }}'::text       AS fingerprint,
    '{{ $json.alertname }}'::text         AS alertname,
    '{{ $json.severity }}'::text          AS severity,
    '{{ $json.status }}'::text            AS status,
    COALESCE(NULLIF('{{ $json.starts_at }}','')::timestamptz, NOW()) AS starts_at,
    NULLIF('{{ $json.ends_at }}','')::timestamptz AS ends_at,
    '{{ $json.generator_url }}'::text     AS generator_url,
    $pl${{ $json.summary }}$pl$::text     AS summary,
    $pl${{ $json.description }}$pl$::text AS description,
    $pl${{ $json.labels_json }}$pl$::jsonb     AS labels,
    $pl${{ $json.annotations_json }}$pl$::jsonb AS annotations
), up AS (
  INSERT INTO system_alerts
    (fingerprint, alertname, severity, status, starts_at, ends_at,
     generator_url, summary, description, labels, annotations,
     last_updated_at)
  SELECT
    fingerprint, alertname, severity, status, starts_at, ends_at,
    generator_url, summary, description, labels, annotations, NOW()
  FROM inputs i
  -- U235 T3: don't insert a brand-new resolved row when we never saw it firing.
  WHERE NOT (
    i.status = 'resolved'
    AND NOT EXISTS (SELECT 1 FROM system_alerts a WHERE a.fingerprint = i.fingerprint)
  )
  ON CONFLICT (fingerprint) DO UPDATE SET
    status          = EXCLUDED.status,
    ends_at         = EXCLUDED.ends_at,
    summary         = EXCLUDED.summary,
    description     = EXCLUDED.description,
    labels          = EXCLUDED.labels,
    annotations     = EXCLUDED.annotations,
    last_updated_at = NOW()
  RETURNING id, alertname, status
)
INSERT INTO audit_log
  (pipeline, action, pipeline_version, result, ai_parsed)
SELECT 'alert_sink',
       up.alertname || ':' || up.status,
       '1.1',
       'success',
       jsonb_build_object('alert_id', up.id,
                          'alertname', up.alertname,
                          'status', up.status,
                          'severity', '{{ $json.severity }}')
  FROM up
RETURNING id AS audit_id;
"""


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
        if n.get('name') == 'Upsert system_alerts + audit':
            params = n.setdefault('parameters', {})
            old = params.get('query', '')
            if 'U235 T3' in old:
                return False  # already patched
            params['query'] = NEW_SQL.strip()
            return True
    raise RuntimeError("Upsert node not found in alert-sink-v1")


def install(current):
    new_uuid = str(uuid.uuid4())
    sql = f"""
BEGIN;
INSERT INTO workflow_history ("versionId", "workflowId", authors, nodes, connections, name, autosaved)
VALUES (
  '{new_uuid}',
  '{WORKFLOW_ID}',
  $authors${current['authors'] or 'u235'}$authors$,
  $nodes${json.dumps(current['nodes'])}$nodes$::json,
  $conns${json.dumps(current['connections'])}$conns$::json,
  $name${current['name']}$name$,
  false
);
UPDATE workflow_entity SET "activeVersionId"='{new_uuid}', "updatedAt"=NOW()
WHERE id='{WORKFLOW_ID}';
SELECT 'rollback' AS k, '{current['current_version']}' AS v;
SELECT 'new_version' AS k, "activeVersionId" AS v FROM workflow_entity WHERE id='{WORKFLOW_ID}';
COMMIT;
"""
    proc = subprocess.run(
        ['docker', 'exec', '-i', 'homeai-postgres', 'psql', '-U', 'postgres', '-d', 'homeai'],
        input=sql, check=True, capture_output=True, text=True,
    )
    print(proc.stdout)
    print(f"✓ patched. rollback: UPDATE workflow_entity SET \"activeVersionId\"='{current['current_version']}' WHERE id='{WORKFLOW_ID}';")


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
        print(f'✗ subprocess failed: {e}\nstderr: {e.stderr}', file=sys.stderr)
        sys.exit(1)
