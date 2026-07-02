#!/usr/bin/env python3
"""
gmail-ingest-parameterize-classified.py — parameterize the Gmail Ingest
"INSERT email.classified" node ($1..$5 + queryReplacement) instead of inline
string interpolation.

Root cause (confirmed, execution 290277 2026-07-02): clsf_payload is raw
JSON.stringify of the classifier output; an apostrophe in the LLM summary
("Jo's business") breaks the inline '...'::jsonb literal ->
`Syntax error at line 5 near "business"`. Same class as the P2 Bug D fix
(p2-parameterize-write.py); pattern copied from the live P2 Write node
(set_config + positional binds, pg-promise escapes each value).

New workflow_history version + repoint activeVersionId, with self-check.
Restart n8n afterwards so the active workflow reloads.
"""
import json, subprocess, sys, uuid, tempfile, os

WF_ID = "gmail-ingest-v1"
PG = ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai"]
NODE = "INSERT email.classified"

NEW_QUERY = """SELECT set_config('app.current_entity', $1::text, true);
INSERT INTO events (event_type, source, entity_id, payload, payload_signature,
                   trace_id, idempotency_key, status, processed_at, pipeline_version)
SELECT 'email.classified', 'email_pipeline', $1::int,
       $2::jsonb,
       $3,
       $4::uuid,
       $5,
       'processed', NOW(), '1.0'
 WHERE NOT EXISTS (
   SELECT 1 FROM events WHERE idempotency_key = $5
 )
RETURNING id;"""

QUERY_REPLACEMENT = ("={{ ["
    "$('Sign Payloads').first().json.ai_entity_id, "
    "$('Sign Payloads').first().json.clsf_payload, "
    "$('Sign Payloads').first().json.clsf_sig, "
    "$('Sign Payloads').first().json.trace_id, "
    "$('Sign Payloads').first().json.idem_classified"
    "] }}")


def psql(sql, tA=False):
    r = subprocess.run(PG + (["-tA"] if tA else []) + ["-c", sql], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"psql failed:\n{r.stderr}\n{r.stdout}")
    return r.stdout.strip()


def main():
    active_vid = psql(f"select \"activeVersionId\" from workflow_entity where id='{WF_ID}';", tA=True)
    meta = json.loads(psql(
        "select json_build_object('authors',authors,'name',name,'description',description) "
        f"from workflow_history where \"versionId\"='{active_vid}';", tA=True))
    graph = json.loads(psql(
        "select json_build_object('nodes',nodes,'connections',connections) "
        f"from workflow_history where \"versionId\"='{active_vid}';", tA=True))
    nodes, conns = graph["nodes"], graph["connections"]
    print(f"loaded active version {active_vid}: {len(nodes)} nodes")

    done = False
    for n in nodes:
        if n["name"] == NODE:
            q = n["parameters"]["query"]
            if "queryReplacement" in json.dumps(n["parameters"].get("options", {})):
                sys.exit("ABORT: queryReplacement already set — already parameterized?")
            if "clsf_payload" not in q or "{{" not in q:
                sys.exit("ABORT: expected inline interpolation not found — node already changed?")
            n["parameters"]["query"] = NEW_QUERY
            opts = n["parameters"].get("options") or {}
            opts["queryReplacement"] = QUERY_REPLACEMENT
            n["parameters"]["options"] = opts
            done = True
    if not done:
        sys.exit("ABORT: node not found")
    print("applied parameterized query + 5-value queryReplacement")

    new_vid = str(uuid.uuid4())
    nd = tempfile.mkdtemp()
    npath, cpath = os.path.join(nd, "nodes.json"), os.path.join(nd, "conns.json")
    json.dump(nodes, open(npath, "w")); json.dump(conns, open(cpath, "w"))
    subprocess.run(["docker", "cp", npath, "homeai-postgres:/tmp/gi_nodes.json"], check=True)
    subprocess.run(["docker", "cp", cpath, "homeai-postgres:/tmp/gi_conns.json"], check=True)

    authors = (meta.get("authors") or "").replace("'", "''")
    name = (meta.get("name") or WF_ID).replace("'", "''")
    desc = (meta.get("description") or "").replace("'", "''")
    sql = f"""
\\set nodes `cat /tmp/gi_nodes.json`
\\set conns `cat /tmp/gi_conns.json`
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

    chk = json.loads(psql(
        "select json_build_object("
        "'active_vid',(select \"activeVersionId\" from workflow_entity where id='" + WF_ID + "'),"
        "'has_param',(select exists(select 1 from json_array_elements((select nodes::json from workflow_history where \"versionId\"='" + new_vid + "')) e where e->>'name'='" + NODE + "' and (e->'parameters'->'options'->>'queryReplacement') like '%clsf_payload%')),"
        "'no_inline',(select not exists(select 1 from json_array_elements((select nodes::json from workflow_history where \"versionId\"='" + new_vid + "')) e where e->>'name'='" + NODE + "' and (e->'parameters'->>'query') like '%{{%'))"
        ");", tA=True))
    print(json.dumps(chk, indent=1))
    ok = chk["active_vid"] == new_vid and chk["has_param"] is True and chk["no_inline"] is True
    print(f"\nnew version: {new_vid}")
    print("SELF-CHECK:", "PASS ✅" if ok else "FAIL ❌")
    print(f"(previous version {active_vid} retained for rollback)")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
