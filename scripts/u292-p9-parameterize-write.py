#!/usr/bin/env python3
"""
u292-p9-parameterize-write.py — same fix as p2-parameterize-write.py, for
Report Ingestion (P9)'s "Upsert Attachment + Audit" write node.

Root cause (confirmed live 2026-07-04): the node inlined the extracted
document text into the SQL as `$pl${{ $json.extracted_text }}$pl$`. When that
text contained a $-prefixed number (quote_4835141.pdf's "$4835141" dollar
amount), the assembled query string held a literal `$4835141`, and n8n's
pg-promise variable parser read it as bind variable #4835141 ->
"Variable $4835141 exceeds supported maximum of $10". EVERY document whose
extracted text contains a $<digits> token 500'd at this node (P9 had 24
errors/24h; the two June quote events looped here, feeding the stale-lease/
dead-letter path). $pl$ dollar-quoting protects Postgres's parser but NOT
pg-promise's pre-execution $N scan.

Fix: bind the free-text + string fields as positional params $1..$9 via the
queryReplacement array (postgres node v2.5). New workflow_history version +
activeVersionId repoint, with self-check. Rollback id printed.
"""
import json, subprocess, sys, uuid, tempfile, os

WF_ID = "report-ingestion-v1"
PG = ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai"]
QUERY_FILE = "/home_ai/scripts/p9_write_param.sql"
WRITE_NODE = "Upsert Attachment + Audit"

# Order MUST match $1..$9 in p9_write_param.sql.
QUERY_REPLACEMENT = ("={{ ["
    "$json.gmail_message_id, $json.event_id, $json.filename, $json.mime_type, "
    "$json.extracted_text, $json.trace_id, $json.ai_raw, $json.outcome_json, "
    "$json.outcome.status"
    "] }}")


def psql(sql, tA=False):
    r = subprocess.run(PG + (["-tA"] if tA else []) + ["-c", sql], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"psql failed:\n{r.stderr}\n{r.stdout}")
    return r.stdout.strip()


def main():
    new_query = open(QUERY_FILE).read()
    # strip -- comment lines before the $N sanity scan (comments quote the
    # error string "...maximum of $10", a false positive otherwise)
    code_only = "\n".join(l for l in new_query.splitlines() if not l.lstrip().startswith("--"))
    for i in range(1, 10):
        if f"${i}" not in code_only:
            sys.exit(f"ABORT: ${i} missing from {QUERY_FILE}")
    if "$10" in code_only:
        sys.exit("ABORT: unexpected $10 in query")

    active_vid = psql(f"select \"activeVersionId\" from workflow_entity where id='{WF_ID}';", tA=True)
    if not active_vid:
        sys.exit(f"ABORT: no active version for {WF_ID}")
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
    print("applied parameterized query + 9-value queryReplacement")

    new_vid = str(uuid.uuid4())
    nd = tempfile.mkdtemp()
    npath, cpath = os.path.join(nd, "nodes.json"), os.path.join(nd, "conns.json")
    json.dump(nodes, open(npath, "w")); json.dump(conns, open(cpath, "w"))
    subprocess.run(["docker", "cp", npath, "homeai-postgres:/tmp/p9p_nodes.json"], check=True)
    subprocess.run(["docker", "cp", cpath, "homeai-postgres:/tmp/p9p_conns.json"], check=True)

    authors = (meta.get("authors") or "").replace("'", "''")
    name = (meta.get("name") or WF_ID).replace("'", "''")
    desc = (meta.get("description") or "").replace("'", "''")
    sql = f"""
\\set nodes `cat /tmp/p9p_nodes.json`
\\set conns `cat /tmp/p9p_conns.json`
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
        "'has_param',(select exists(select 1 from json_array_elements((select nodes::json from workflow_history where \"versionId\"='" + new_vid + "')) e where e->>'name'='" + WRITE_NODE + "' and (e->'parameters'->'options'->>'queryReplacement') like '%extracted_text%')),"
        "'no_pl',(select not exists(select 1 from json_array_elements((select nodes::json from workflow_history where \"versionId\"='" + new_vid + "')) e where e->>'name'='" + WRITE_NODE + "' and (e->'parameters'->>'query') like '%pl$%'))"
        ");", tA=True))
    print(json.dumps(chk, indent=1))
    ok = chk["active_vid"] == new_vid and chk["has_param"] is True and chk["no_pl"] is True
    print(f"\nnew version: {new_vid}")
    print("SELF-CHECK:", "PASS" if ok else "FAIL")
    print(f"rollback: UPDATE workflow_entity SET \"activeVersionId\"='{active_vid}' WHERE id='{WF_ID}';")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
