#!/usr/bin/env python3
"""
p6-fix-parse-regex.py — repair the P6 Caterbook "Parse Accommodation Report"
Code node, broken since its 2026-06-14 rewrite (100% error every 15 min).

Root cause: one escaping level was eaten when the node was saved:
  - `.replace(/\r/g,'')` became `.replace(/<literal CR>/g,'')` -> JS
    SyntaxError "Invalid regular expression: missing /" on every run.
  - `new RegExp('(\\d+)\\s*'...)` lost its double backslashes -> '\d' parses
    as 'd' in a JS string, so counts would never match anyway.
Also wraps the label alternation in a non-capturing group so
'stay-through|stayover' binds correctly.

Fix validated in-container (node) against the live email format:
  "…your 6 arrival(s), 4 stay-through(s), and 3 departure(s) for today."
New workflow_history version + repoint activeVersionId, with self-check.
"""
import json, subprocess, sys, uuid, tempfile, os

WF_ID = "caterbook-pipeline-v1"
PG = ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai"]
NODE = "Parse Accommodation Report"

BROKEN_REPLACE = "').replace(/\r/g, '');"          # literal CR in source
FIXED_REPLACE = "').replace(/\\r/g, '');"          # \r regex escape
BROKEN_REGEXP = "new RegExp('(\\d+)\\s*' + label + '\\s*\\(', 'i');"
FIXED_REGEXP = "new RegExp('(\\\\d+)\\\\s*(?:' + label + ')\\\\s*\\\\(', 'i');"


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
            if BROKEN_REPLACE not in code:
                sys.exit("ABORT: literal-CR replace() not found — node already changed?")
            if BROKEN_REGEXP not in code:
                sys.exit("ABORT: single-backslash RegExp not found — node already changed?")
            code = code.replace(BROKEN_REPLACE, FIXED_REPLACE)
            code = code.replace(BROKEN_REGEXP, FIXED_REGEXP)
            n["parameters"]["jsCode"] = code
            done = True
    if not done:
        sys.exit("ABORT: node not found")
    print("applied regex repairs")

    new_vid = str(uuid.uuid4())
    nd = tempfile.mkdtemp()
    npath, cpath = os.path.join(nd, "nodes.json"), os.path.join(nd, "conns.json")
    json.dump(nodes, open(npath, "w")); json.dump(conns, open(cpath, "w"))
    subprocess.run(["docker", "cp", npath, "homeai-postgres:/tmp/p6_nodes.json"], check=True)
    subprocess.run(["docker", "cp", cpath, "homeai-postgres:/tmp/p6_conns.json"], check=True)

    authors = (meta.get("authors") or "").replace("'", "''")
    name = (meta.get("name") or WF_ID).replace("'", "''")
    desc = (meta.get("description") or "").replace("'", "''")
    sql = f"""
\\set nodes `cat /tmp/p6_nodes.json`
\\set conns `cat /tmp/p6_conns.json`
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
    ok = chk_vid == new_vid and FIXED_REPLACE in code_now and "\r/g" not in code_now.replace("\\r/g", "")
    print(f"\nnew version: {new_vid}")
    print("SELF-CHECK:", "PASS ✅" if ok else "FAIL ❌")
    print(f"(previous version {active_vid} retained for rollback)")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
