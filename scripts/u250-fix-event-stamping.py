#!/usr/bin/env python3
"""
u250-fix-event-stamping.py — P2 of U250: events inserted born-terminal
('processed'/'done') never set processed_at, so the unprocessed-backlog metric
counts thousands of rows that were in fact handled. Adds processed_at=NOW()
to every born-terminal INSERT INTO events across four workflows.

Same mechanism as p2-fix-complete-event.py (U243): new workflow_history row +
repoint workflow_entity.activeVersionId, previous version retained for
rollback. Idempotent: skips a workflow whose node already mentions
processed_at in the INSERT.
"""
import json, subprocess, sys, uuid, tempfile, os

PG = ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai"]

# (workflow_id, node_name, [(anchor, replacement), ...])
PATCHES = [
    ("gmail-ingest-v1", "INSERT email.classified", [
        ("idempotency_key, status, pipeline_version)",
         "idempotency_key, status, processed_at, pipeline_version)"),
        ("'processed', '1.0'",
         "'processed', NOW(), '1.0'"),
    ]),
    ("invoice-pipeline-v1", "Write Invoice + History + Event + Audit", [
        ("status, idempotency_key, pipeline_version, parent_event_id, trace_id)",
         "status, processed_at, idempotency_key, pipeline_version, parent_event_id, trace_id)"),
        ("'done', $19, '1.0', $2, $3::uuid",
         "'done', NOW(), $19, '1.0', $2, $3::uuid"),
    ]),
    ("bank-csv-import-v1", "Write Event + Audit", [
        ("status, idempotency_key, pipeline_version)",
         "status, processed_at, idempotency_key, pipeline_version)"),
        ("         'done',\n",
         "         'done', NOW(),\n"),
    ]),
    ("partition-maintenance-v1", "Write Event + Audit", [
        ("status, idempotency_key, pipeline_version)",
         "status, processed_at, idempotency_key, pipeline_version)"),
        ("         'done',\n",
         "         'done', NOW(),\n"),
    ]),
]


def psql(sql, tA=False):
    r = subprocess.run(PG + (["-tA"] if tA else []) + ["-c", sql],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"psql failed:\n{r.stderr}\n{r.stdout}")
    return r.stdout.strip()


def patch_workflow(wf_id, node_name, repls):
    active_vid = psql(
        f"select \"activeVersionId\" from workflow_entity where id='{wf_id}';", tA=True)
    if not active_vid:
        sys.exit(f"ABORT: workflow {wf_id} not found")
    meta = json.loads(psql(
        "select json_build_object('authors',authors,'name',name,'description',description) "
        f"from workflow_history where \"versionId\"='{active_vid}';", tA=True))
    graph = json.loads(psql(
        "select json_build_object('nodes',nodes,'connections',connections) "
        f"from workflow_history where \"versionId\"='{active_vid}';", tA=True))
    nodes, conns = graph["nodes"], graph["connections"]

    target = next((n for n in nodes if n["name"] == node_name), None)
    if target is None:
        sys.exit(f"ABORT: node '{node_name}' not found in {wf_id}")
    q = target["parameters"]["query"]
    if "processed_at" in q.split("INSERT INTO events", 1)[-1][:600]:
        print(f"  {wf_id}: already stamped — skipping")
        return None
    for anchor, repl in repls:
        if anchor not in q:
            sys.exit(f"ABORT: anchor not found in {wf_id}/{node_name}:\n{anchor!r}")
        if q.count(anchor) != 1:
            sys.exit(f"ABORT: anchor not unique in {wf_id}/{node_name}:\n{anchor!r}")
        q = q.replace(anchor, repl)
    target["parameters"]["query"] = q

    new_vid = str(uuid.uuid4())
    nd = tempfile.mkdtemp()
    npath, cpath = os.path.join(nd, "nodes.json"), os.path.join(nd, "conns.json")
    json.dump(nodes, open(npath, "w")); json.dump(conns, open(cpath, "w"))
    subprocess.run(["docker", "cp", npath, "homeai-postgres:/tmp/u250_nodes.json"], check=True)
    subprocess.run(["docker", "cp", cpath, "homeai-postgres:/tmp/u250_conns.json"], check=True)

    authors = (meta.get("authors") or "").replace("'", "''")
    name = (meta.get("name") or wf_id).replace("'", "''")
    desc = (meta.get("description") or "").replace("'", "''")
    sql = f"""
\\set nodes `cat /tmp/u250_nodes.json`
\\set conns `cat /tmp/u250_conns.json`
BEGIN;
INSERT INTO workflow_history ("versionId","workflowId",authors,"createdAt","updatedAt",
                              nodes,connections,name,autosaved,description)
VALUES ('{new_vid}','{wf_id}','{authors}',now(),now(),
        :'nodes'::json, :'conns'::json, '{name}', false, '{desc}');
UPDATE workflow_entity
   SET nodes=:'nodes'::json, connections=:'conns'::json,
       "activeVersionId"='{new_vid}', "updatedAt"=now()
 WHERE id='{wf_id}';
COMMIT;
"""
    r = subprocess.run(PG + ["-v", "ON_ERROR_STOP=1"], input=sql,
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"DB write failed for {wf_id}:\n{r.stderr}\n{r.stdout}")

    chk_vid = psql(f"select \"activeVersionId\" from workflow_entity where id='{wf_id}';", tA=True)
    ok = chk_vid == new_vid
    print(f"  {wf_id}: {active_vid} -> {new_vid}  {'PASS' if ok else 'FAIL'}")
    if not ok:
        sys.exit(1)
    return new_vid


def main():
    for wf_id, node_name, repls in PATCHES:
        print(f"patching {wf_id} / {node_name}")
        patch_workflow(wf_id, node_name, repls)
    print("all patches applied")


if __name__ == "__main__":
    main()
