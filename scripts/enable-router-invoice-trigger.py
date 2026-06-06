#!/usr/bin/env python3
"""
enable-router-invoice-trigger.py — the Master Router routes invoice.detected to
its 'Trigger Invoice Pipeline' node, but that node is disabled (V224 stopgap), so
claimed invoice.detected events never reach P2 (they pile in 'processing'). This
removes the `disabled` flag so the router fires P2.

Safe on its own: invoice.detected is currently excluded from claim_event_batch, so
nothing is claimed/triggered until a separate re-admit. New workflow_history
version + repoint activeVersionId, with self-check.
"""
import json, subprocess, sys, uuid, tempfile, os

PG = ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai"]
NODE = "Trigger Invoice Pipeline"


def psql(sql, tA=False):
    r = subprocess.run(PG + (["-tA"] if tA else []) + ["-c", sql], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"psql failed:\n{r.stderr}\n{r.stdout}")
    return r.stdout.strip()


def main():
    wf_id = psql("select id from workflow_entity where name ilike '%master%router%';", tA=True)
    active_vid = psql(f"select \"activeVersionId\" from workflow_entity where id='{wf_id}';", tA=True)
    print(f"Master Router id={wf_id} active version={active_vid}")
    meta = json.loads(psql(
        "select json_build_object('authors',authors,'name',name,'description',description) "
        f"from workflow_history where \"versionId\"='{active_vid}';", tA=True))
    graph = json.loads(psql(
        "select json_build_object('nodes',nodes,'connections',connections) "
        f"from workflow_history where \"versionId\"='{active_vid}';", tA=True))
    nodes, conns = graph["nodes"], graph["connections"]

    found = False
    for n in nodes:
        if n["name"] == NODE:
            if not n.get("disabled"):
                sys.exit(f"ABORT: '{NODE}' is already enabled (disabled={n.get('disabled')})")
            n.pop("disabled", None)
            found = True
    if not found:
        sys.exit(f"ABORT: node '{NODE}' not found")
    print(f"removed disabled flag from '{NODE}'")

    new_vid = str(uuid.uuid4())
    nd = tempfile.mkdtemp()
    npath, cpath = os.path.join(nd, "nodes.json"), os.path.join(nd, "conns.json")
    json.dump(nodes, open(npath, "w")); json.dump(conns, open(cpath, "w"))
    subprocess.run(["docker", "cp", npath, "homeai-postgres:/tmp/mr_nodes.json"], check=True)
    subprocess.run(["docker", "cp", cpath, "homeai-postgres:/tmp/mr_conns.json"], check=True)

    authors = (meta.get("authors") or "").replace("'", "''")
    name = (meta.get("name") or wf_id).replace("'", "''")
    desc = (meta.get("description") or "").replace("'", "''")
    sql = f"""
\\set nodes `cat /tmp/mr_nodes.json`
\\set conns `cat /tmp/mr_conns.json`
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
    r = subprocess.run(PG + ["-v", "ON_ERROR_STOP=1"], input=sql, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"DB write failed:\n{r.stderr}\n{r.stdout}")

    chk = json.loads(psql(
        "select json_build_object("
        "'active_vid',(select \"activeVersionId\" from workflow_entity where id='" + wf_id + "'),"
        "'still_disabled',(select exists(select 1 from json_array_elements((select nodes::json from workflow_history where \"versionId\"='" + new_vid + "')) e where e->>'name'='" + NODE + "' and e ? 'disabled'))"
        ");", tA=True))
    print(json.dumps(chk, indent=1))
    ok = chk["active_vid"] == new_vid and chk["still_disabled"] is False
    print(f"\nnew Master Router version: {new_vid}")
    print("SELF-CHECK:", "PASS ✅" if ok else "FAIL ❌")
    print(f"(previous version {active_vid} retained for rollback)")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
