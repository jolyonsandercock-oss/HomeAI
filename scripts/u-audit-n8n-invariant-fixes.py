#!/usr/bin/env python3
"""u-audit-n8n-invariant-fixes.py — apply the 2026-06-07 audit fixes to live
n8n workflows + their repo exports.

Fixes:
  INV-ENTITY-LOCAL: bare `SET app.current_entity` → `SET LOCAL app.current_entity`
                    (bare SET leaks the GUC to the next query on a pooled conn).
  F6 (nanny):       drop the raw `|| payload.body_text` fallback in the
                    'Validate Event' node so AI input uses body_text_safe only.

Method (per the proven u235 pattern): read the active workflow_history version,
transform its nodes, INSERT a NEW history row, repoint activeVersionId AND
workflow_entity.nodes. Prints rollback SQL. Idempotent (skips if unchanged).
Also mirrors the change into .claude/n8n-exports/<file>.json.

Run with pipelines PAUSED (kill switch). Restart homeai-n8n afterwards so the
active-workflow runner reloads the new versions.
"""
import json
import re
import subprocess
import sys
import uuid

PG = ['docker', 'exec', '-i', 'homeai-postgres', 'psql', '-U', 'postgres', '-d', 'homeai']
EXPORT_DIR = '/home_ai/.claude/n8n-exports'

# workflow_id -> export filename
EXPORT = {
    'caterbook-bookings-v1': 'caterbook-bookings-v1.json',
    'caterbook-pipeline-v1': 'caterbook-pipeline-v1.json',
    'epos-pipeline-v1':      'epos-pipeline-v1.json',
    'gmail-ingest-v1':       'gmail-ingest.json',
    'pub-anomaly-alerter-v1':'pub-anomaly-alerter-v1.json',
    'telegram-bot-v1':       'telegram-bot-v1.json',
    'nanny-v1':              'nanny.json',
}

ENTITY_LOCAL_WFS = [
    'caterbook-bookings-v1', 'caterbook-pipeline-v1', 'epos-pipeline-v1',
    'gmail-ingest-v1', 'pub-anomaly-alerter-v1', 'telegram-bot-v1',
]
NANNY_WF = 'nanny-v1'

NANNY_OLD = "payload.body_text_safe || payload.body_text || ''"
NANNY_NEW = "payload.body_text_safe || ''"


def transform_entity_local(node) -> bool:
    """SET app.current_entity -> SET LOCAL app.current_entity in a node's query."""
    p = node.get('parameters')
    if not isinstance(p, dict) or not isinstance(p.get('query'), str):
        return False
    q = p['query']
    # only bare 'SET app.current_entity' (not the already-LOCAL form, which the
    # substring 'SET app.current_entity' does not appear in)
    if 'SET app.current_entity' not in q:
        return False
    p['query'] = q.replace('SET app.current_entity', 'SET LOCAL app.current_entity')
    return True


def transform_nanny(node) -> bool:
    p = node.get('parameters')
    if not isinstance(p, dict) or not isinstance(p.get('jsCode'), str):
        return False
    if NANNY_OLD not in p['jsCode']:
        return False
    p['jsCode'] = p['jsCode'].replace(NANNY_OLD, NANNY_NEW)
    return True


def psql(sql: str) -> str:
    r = subprocess.run(PG, input=sql, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"psql failed: {r.stderr}")
    return r.stdout


def fetch_active(wf_id: str):
    # -tA = tuples-only, unaligned (no '\pset' confirmation lines in output)
    r = subprocess.run(
        ['docker', 'exec', '-i', 'homeai-postgres', 'psql', '-U', 'postgres',
         '-d', 'homeai', '-tA', '-c', f"""
SELECT row_to_json(t) FROM (
  SELECT h."versionId" v, h.nodes::text nodes, h.connections::text connections,
         COALESCE(h.name, e.name, '{wf_id}') name,
         COALESCE(h.authors, 'u-audit') authors
  FROM workflow_history h
  JOIN workflow_entity e ON e.id = h."workflowId"
  WHERE h."versionId" = (SELECT "activeVersionId" FROM workflow_entity WHERE id='{wf_id}')
) t;"""],
        capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"fetch failed for {wf_id}: {r.stderr}")
    out = r.stdout.strip()
    if not out:
        raise RuntimeError(f"no active history for {wf_id}")
    d = json.loads(out)
    return d['v'], json.loads(d['nodes']), json.loads(d['connections']), d['name'], d['authors']


def dq(tag_base: str, payload: str) -> str:
    """Dollar-quote payload with a tag guaranteed not to collide."""
    tag = f"${tag_base}_{uuid.uuid4().hex[:8]}$"
    assert tag not in payload
    return f"{tag}{payload}{tag}"


def install(wf_id, nodes, connections, name, authors, old_version):
    new_v = str(uuid.uuid4())
    nodes_s = json.dumps(nodes)
    conns_s = json.dumps(connections)
    sql = f"""\\set ON_ERROR_STOP on
BEGIN;
INSERT INTO workflow_history ("versionId","workflowId",authors,nodes,connections,name,autosaved)
VALUES ('{new_v}','{wf_id}',{dq('a', authors or 'u-audit')},
        {dq('n', nodes_s)}::json,{dq('c', conns_s)}::json,{dq('m', name)},false);
UPDATE workflow_entity
   SET "activeVersionId"='{new_v}', nodes={dq('n2', nodes_s)}::json, "updatedAt"=NOW()
 WHERE id='{wf_id}';
COMMIT;
"""
    psql(sql)
    print(f"  ✓ {wf_id}: new version {new_v}  (rollback: UPDATE workflow_entity "
          f"SET \"activeVersionId\"='{old_version}' WHERE id='{wf_id}';)")


def patch_export(wf_id, transform):
    fn = EXPORT.get(wf_id)
    if not fn:
        return
    path = f"{EXPORT_DIR}/{fn}"
    raw = open(path).read()
    data = json.loads(raw)
    changed = []
    def walk(o):
        if isinstance(o, dict):
            if transform.__name__ == 'transform_entity_local' and isinstance(o.get('parameters'), dict) \
               and isinstance(o['parameters'].get('query'), str):
                old = o['parameters']['query']
                if transform(o):
                    changed.append((old, o['parameters']['query'], 'query'))
            if transform.__name__ == 'transform_nanny' and isinstance(o.get('parameters'), dict) \
               and isinstance(o['parameters'].get('jsCode'), str):
                old = o['parameters']['jsCode']
                if transform(o):
                    changed.append((old, o['parameters']['jsCode'], 'jsCode'))
            for v in o.values(): walk(v)
        elif isinstance(o, list):
            for v in o: walk(v)
    walk(data)
    for old, new, _ in changed:
        raw = raw.replace(json.dumps(old), json.dumps(new))
    if changed:
        open(path, 'w').write(raw)
    print(f"    export {fn}: {len(changed)} node(s) updated")


def run_workflow(wf_id, transform):
    old_v, nodes, conns, name, authors = fetch_active(wf_id)
    n = sum(1 for node in nodes if transform(node))
    if n == 0:
        print(f"  – {wf_id}: already clean (0 nodes)")
        return
    print(f"  {wf_id} ({name}): {n} node(s) to patch")
    install(wf_id, nodes, conns, name, authors, old_v)
    patch_export(wf_id, transform)


def main():
    print("== INV-ENTITY-LOCAL: SET -> SET LOCAL ==")
    for wf in ENTITY_LOCAL_WFS:
        run_workflow(wf, transform_entity_local)
    print("== F6: nanny body_text fallback ==")
    run_workflow(NANNY_WF, transform_nanny)


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        print(f"✗ {e}", file=sys.stderr)
        sys.exit(1)
