#!/usr/bin/env python3
"""
p6-fix-parseable-gate.py — P6 fix #3. The report_date defaulting (fix #2)
regressed the Parseable? gate: reportDate is now ALWAYS set, so `parseable`
became always-true and empty poll cycles ({success:true} sentinel items with
no email_id) flow to "Insert accommodation_daily", rendering `undefined` into
the SQL -> `column "undefined" does not exist` every 15 min since ~18:30.

Fix: capture dateExplicit BEFORE the default (restoring the original gate
semantics) and require email_id for parseability. Empty/sentinel items route
to "Log unparseable" exactly as pre-06-14 behaviour.
"""
import json, subprocess, sys, uuid, tempfile, os

WF_ID = "caterbook-pipeline-v1"
PG = ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai"]
NODE = "Parse Accommodation Report"

OLD_DEFAULT = "if (!reportDate) reportDate = baseDate.toISOString().slice(0, 10);"
NEW_DEFAULT = """const dateExplicit = !!reportDate;
if (!reportDate) reportDate = baseDate.toISOString().slice(0, 10);"""

OLD_PARSEABLE = "const parseable = !!(reportDate || (arrivals !== null && departures !== null));"
NEW_PARSEABLE = "const parseable = !!($json.email_id && (dateExplicit || (arrivals !== null && departures !== null)));"


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
            code = n["parameters"]["jsCode"]
            if "dateExplicit" in code:
                sys.exit("ABORT: already patched")
            if OLD_DEFAULT not in code or OLD_PARSEABLE not in code:
                sys.exit("ABORT: expected lines not found — node changed?")
            code = code.replace(OLD_DEFAULT, NEW_DEFAULT).replace(OLD_PARSEABLE, NEW_PARSEABLE)
            n["parameters"]["jsCode"] = code
            done = True
    if not done:
        sys.exit("ABORT: node not found")
    print("applied parseable-gate repair")

    new_vid = str(uuid.uuid4())
    nd = tempfile.mkdtemp()
    npath, cpath = os.path.join(nd, "nodes.json"), os.path.join(nd, "conns.json")
    json.dump(nodes, open(npath, "w")); json.dump(conns, open(cpath, "w"))
    subprocess.run(["docker", "cp", npath, "homeai-postgres:/tmp/p6g_nodes.json"], check=True)
    subprocess.run(["docker", "cp", cpath, "homeai-postgres:/tmp/p6g_conns.json"], check=True)

    authors = (meta.get("authors") or "").replace("'", "''")
    name = (meta.get("name") or WF_ID).replace("'", "''")
    desc = (meta.get("description") or "").replace("'", "''")
    sql = f"""
\\set nodes `cat /tmp/p6g_nodes.json`
\\set conns `cat /tmp/p6g_conns.json`
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

    chk_vid = psql(f"select \"activeVersionId\" from workflow_entity where id='{WF_ID}';", tA=True)
    code_now = psql(
        "select e->'parameters'->>'jsCode' from workflow_history wh, "
        "json_array_elements(wh.nodes::json) e "
        f"where wh.\"versionId\"='{new_vid}' and e->>'name'='{NODE}';", tA=True)
    ok = chk_vid == new_vid and "dateExplicit" in code_now and "$json.email_id && (dateExplicit" in code_now
    print(f"\nnew version: {new_vid}")
    print("SELF-CHECK:", "PASS ✅" if ok else "FAIL ❌")
    print(f"(previous version {active_vid} retained for rollback)")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
