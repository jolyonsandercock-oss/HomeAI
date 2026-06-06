#!/usr/bin/env python3
"""
p2-dwd-surgery.py — U243 S3 build: make Invoice Pipeline (P2) fetch attachments
through google-fetch (DWD-safe) instead of its OAuth-only Gmail chain.

Per the n8n DB-edit pattern (feedback_n8n_workflow_history_runtime): the runtime
reads workflow_history via workflow_entity.activeVersionId, so we INSERT a new
history row and repoint activeVersionId (and keep workflow_entity in sync for the UI).

Transform (spec 2026-06-05-invoice-p2-dwd-attachment-fetch.md):
  REMOVE : Vault: Gmail Creds, OAuth: Refresh Access Token, Gmail: Fetch Attachment
  ADD    : Fetch Attachment (google-fetch)  -> GET homeai-google-fetch:8011/attachment/{acct}/{msg}/{att}
  EDIT   : Decode + Build Form  -> read data_b64url (was Gmail's `data`)
  REWIRE : Merge Attachment Meta -> Vault: Signing Key -> Vault: Anthropic Key
           -> Fetch Attachment (google-fetch) -> Decode + Build Form

Idempotent-safe: refuses to run if the new node already exists in the active version.
Workflow is left active=false. Re-enable is a separate attended step.
"""
import json, subprocess, sys, uuid, datetime, tempfile, os

WF_ID = "invoice-pipeline-v1"
PG = ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai"]
REMOVE = {"Vault: Gmail Creds", "OAuth: Refresh Access Token", "Gmail: Fetch Attachment"}
NEW_NODE_NAME = "Fetch Attachment (google-fetch)"
GF_URL = ("=http://homeai-google-fetch:8011/attachment/"
          "{{ $('Merge Attachment Meta').first().json.account }}/"
          "{{ $('Merge Attachment Meta').first().json.gmail_message_id }}/"
          "{{ $('Merge Attachment Meta').first().json.attachment_id }}")


def psql(sql, tA=False):
    args = PG + (["-tA"] if tA else []) + ["-c", sql]
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"psql failed:\n{r.stderr}\n{r.stdout}")
    return r.stdout.strip()


def main():
    # 1. Load current active version (authoritative source = workflow_history).
    active_vid = psql(f"select \"activeVersionId\" from workflow_entity where id='{WF_ID}';", tA=True)
    meta = psql(
        "select json_build_object('authors',authors,'name',name,'description',description,"
        f"'workflowId',\"workflowId\") from workflow_history where \"versionId\"='{active_vid}';", tA=True)
    meta = json.loads(meta)
    graph = json.loads(psql(
        "select json_build_object('nodes',nodes,'connections',connections) "
        f"from workflow_history where \"versionId\"='{active_vid}';", tA=True))
    nodes, conns = graph["nodes"], graph["connections"]
    names = {n["name"] for n in nodes}
    print(f"loaded active version {active_vid}: {len(nodes)} nodes")

    if NEW_NODE_NAME in names:
        sys.exit(f"ABORT: '{NEW_NODE_NAME}' already present — surgery already applied?")
    missing = REMOVE - names
    if missing:
        sys.exit(f"ABORT: expected nodes to remove not found: {missing}")

    # 2. Remove the three OAuth-only nodes.
    nodes = [n for n in nodes if n["name"] not in REMOVE]

    # 3. Add the google-fetch HTTP node (where OAuth: Refresh used to sit).
    nodes.append({
        "id": "p2-0009b-gf-fetch",
        "name": NEW_NODE_NAME,
        "type": "n8n-nodes-base.httpRequest",
        "typeVersion": 4.2,
        "position": [1620, 300],
        "parameters": {
            "url": GF_URL,
            "method": "GET",
            "options": {"timeout": 30000},
        },
    })

    # 4. Edit Decode + Build Form to read data_b64url (google-fetch field).
    for n in nodes:
        if n["name"] == "Decode + Build Form":
            code = n["parameters"]["jsCode"]
            assert "att.data" in code, "Decode node no longer references att.data"
            code = code.replace("att.data", "att.data_b64url")
            code = code.replace("Gmail attachment fetch returned no data",
                                "google-fetch returned no attachment data (data_b64url empty)")
            n["parameters"]["jsCode"] = code

    # 5. Rewire connections.
    for r in REMOVE:
        conns.pop(r, None)
    conns["Merge Attachment Meta"] = {"main": [[{"node": "Vault: Signing Key", "type": "main", "index": 0}]]}
    conns["Vault: Anthropic Key"] = {"main": [[{"node": NEW_NODE_NAME, "type": "main", "index": 0}]]}
    conns[NEW_NODE_NAME] = {"main": [[{"node": "Decode + Build Form", "type": "main", "index": 0}]]}

    # 5b. Validate: no connection references a removed/absent node.
    final_names = {n["name"] for n in nodes}
    for src, spec in conns.items():
        if src not in final_names:
            sys.exit(f"ABORT: connection source '{src}' is not a node")
        for lst in spec.get("main", []):
            for c in lst:
                if c["node"] not in final_names:
                    sys.exit(f"ABORT: connection '{src}' -> '{c['node']}' targets a missing node")

    # 6. Write new version into the DB (new history row + repoint, in one txn).
    new_vid = str(uuid.uuid4())
    nd, cn = tempfile.mkdtemp(), None
    npath, cpath = os.path.join(nd, "nodes.json"), os.path.join(nd, "conns.json")
    json.dump(nodes, open(npath, "w")); json.dump(conns, open(cpath, "w"))
    subprocess.run(["docker", "cp", npath, "homeai-postgres:/tmp/p2_nodes.json"], check=True)
    subprocess.run(["docker", "cp", cpath, "homeai-postgres:/tmp/p2_conns.json"], check=True)

    ent_name = psql(f"select name from workflow_entity where id='{WF_ID}';", tA=True)
    authors = (meta.get("authors") or "").replace("'", "''")
    name = (meta.get("name") or ent_name or WF_ID).replace("'", "''")
    desc = (meta.get("description") or "").replace("'", "''")
    sql = f"""
\\set nodes `cat /tmp/p2_nodes.json`
\\set conns `cat /tmp/p2_conns.json`
BEGIN;
INSERT INTO workflow_history ("versionId","workflowId",authors,"createdAt","updatedAt",
                              nodes,connections,name,autosaved,description)
VALUES ('{new_vid}','{WF_ID}','{authors}',now(),now(),
        :'nodes'::json, :'conns'::json, '{name}', false, '{desc}');
UPDATE workflow_entity
   SET nodes=:'nodes'::json, connections=:'conns'::json,
       "activeVersionId"='{new_vid}', "updatedAt"=now()
 WHERE id='{WF_ID}';
COMMIT;
"""
    r = subprocess.run(PG + ["-v", "ON_ERROR_STOP=1"], input=sql, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"DB write failed:\n{r.stderr}\n{r.stdout}")

    # 7. Round-trip self-check from the DB.
    check = json.loads(psql(
        "select json_build_object("
        "'active_vid',(select \"activeVersionId\" from workflow_entity where id='" + WF_ID + "'),"
        "'active',(select active from workflow_entity where id='" + WF_ID + "'),"
        "'hist_nodes',(select json_array_length(nodes::json) from workflow_history where \"versionId\"='" + new_vid + "'),"
        "'has_new',(select exists(select 1 from json_array_elements((select nodes::json from workflow_history where \"versionId\"='" + new_vid + "')) e where e->>'name'='" + NEW_NODE_NAME + "')),"
        "'has_removed',(select exists(select 1 from json_array_elements((select nodes::json from workflow_history where \"versionId\"='" + new_vid + "')) e where e->>'name' in ('Vault: Gmail Creds','OAuth: Refresh Access Token','Gmail: Fetch Attachment')))"
        ");", tA=True))
    print(json.dumps(check, indent=1))
    ok = (check["active_vid"] == new_vid and check["active"] is False
          and check["has_new"] is True and check["has_removed"] is False
          and check["hist_nodes"] == len(nodes))
    print(f"\nnew version: {new_vid}")
    print("SELF-CHECK:", "PASS ✅" if ok else "FAIL ❌")
    print(f"(previous version {active_vid} retained in history for rollback)")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
