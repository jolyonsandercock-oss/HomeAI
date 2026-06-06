#!/usr/bin/env python3
"""
p2-parameterize-write.py — Bug D fix: rewrite the P2 Write node to use
parameterized queries ($1..$22 + queryReplacement array) instead of inline
string interpolation.

Root cause (confirmed): the old node interpolated values into the SQL, so a
value starting with a digit became `$pl$307802162$pl$`, and n8n's pg-promise
variable parser read the `$307802162` as bind variable #307802162 -> "Variable
$307802162 exceeds supported maximum of $100000". Numeric invoice numbers/amounts
are common, so a large fraction of the backlog 500'd.

Fix: all dynamic values pass as positional params. n8n postgres node v2.5 uses
the queryReplacement array directly as values (Array.isArray branch); pg-promise
escapes each value, so digits-leading values and literal `$` in content are safe.
The new SQL was validated via PREPARE/EXECUTE with invoice_number='307802162'.

New workflow_history version + repoint activeVersionId, with self-check.
"""
import json, subprocess, sys, uuid, tempfile, os

WF_ID = "invoice-pipeline-v1"
PG = ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai"]
QUERY_FILE = "/tmp/p2_write_param.sql"
WRITE_NODE = "Write Invoice + History + Event + Audit"

# Order MUST match $1..$22 in p2_write_param.sql.
QUERY_REPLACEMENT = ("={{ ["
    "$json.idempotency_key, $json.event_id, $json.trace_id, $json.entity_id, "
    "$json.supplier_name, $json.invoice_number, $json.invoice_date, $json.due_date, "
    "$json.gross_amount, $json.net_amount, $json.vat_amount, $json.currency, "
    "$json.category, $json.confidence, $json.requires_human, $json.out_event_type, "
    "$json.out_event_payload_json, $json.out_event_signature, $json.out_event_idem_key, "
    "$json.ai_raw, $json.outcome_json, $json.outcome.status"
    "] }}")


def psql(sql, tA=False):
    r = subprocess.run(PG + (["-tA"] if tA else []) + ["-c", sql], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"psql failed:\n{r.stderr}\n{r.stdout}")
    return r.stdout.strip()


def main():
    new_query = open(QUERY_FILE).read()
    # sanity: 22 distinct placeholders present
    for i in range(1, 23):
        if f"${i}" not in new_query:
            sys.exit(f"ABORT: ${i} missing from {QUERY_FILE}")
    if "$23" in new_query:
        sys.exit("ABORT: unexpected $23 in query")

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
        if n["name"] == WRITE_NODE:
            q = n["parameters"]["query"]
            if "queryReplacement" in json.dumps(n["parameters"].get("options", {})):
                sys.exit("ABORT: queryReplacement already set — already parameterized?")
            if "$pl$" not in q:
                sys.exit("ABORT: expected $pl$ interpolation not found — node already changed?")
            n["parameters"]["query"] = new_query
            opts = n["parameters"].get("options", {})
            opts["queryReplacement"] = QUERY_REPLACEMENT
            n["parameters"]["options"] = opts
            done = True
    if not done:
        sys.exit("ABORT: Write node not found")
    print("applied parameterized query + 22-value queryReplacement")

    new_vid = str(uuid.uuid4())
    nd = tempfile.mkdtemp()
    npath, cpath = os.path.join(nd, "nodes.json"), os.path.join(nd, "conns.json")
    json.dump(nodes, open(npath, "w")); json.dump(conns, open(cpath, "w"))
    subprocess.run(["docker", "cp", npath, "homeai-postgres:/tmp/p2p_nodes.json"], check=True)
    subprocess.run(["docker", "cp", cpath, "homeai-postgres:/tmp/p2p_conns.json"], check=True)

    authors = (meta.get("authors") or "").replace("'", "''")
    name = (meta.get("name") or WF_ID).replace("'", "''")
    desc = (meta.get("description") or "").replace("'", "''")
    sql = f"""
\\set nodes `cat /tmp/p2p_nodes.json`
\\set conns `cat /tmp/p2p_conns.json`
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
        "'has_param',(select exists(select 1 from json_array_elements((select nodes::json from workflow_history where \"versionId\"='" + new_vid + "')) e where e->>'name'='" + WRITE_NODE + "' and (e->'parameters'->'options'->>'queryReplacement') like '%idempotency_key%')),"
        "'no_pl',(select not exists(select 1 from json_array_elements((select nodes::json from workflow_history where \"versionId\"='" + new_vid + "')) e where e->>'name'='" + WRITE_NODE + "' and (e->'parameters'->>'query') like '%pl$%'))"
        ");", tA=True))
    print(json.dumps(chk, indent=1))
    ok = chk["active_vid"] == new_vid and chk["has_param"] is True and chk["no_pl"] is True
    print(f"\nnew version: {new_vid}")
    print("SELF-CHECK:", "PASS ✅" if ok else "FAIL ❌")
    print(f"(previous version {active_vid} retained for rollback)")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
