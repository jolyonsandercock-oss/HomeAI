#!/usr/bin/env python3
"""
p2-fix-outcome-write.py — fix two pre-existing P2 bugs surfaced by the first
end-to-end DWD test (event 14504). Both block every invoice write; neither is
related to the DWD attachment-fetch change.

Bug B (Build OutcomeObject + Idem Key): JSON.parse runs on Haiku's raw text,
  but Haiku 4.5 wraps the JSON in a ```json ... ``` markdown fence, so the parse
  throws and the catch fills empty defaults (supplier='', gross 0). Fix: strip
  the fence (and fall back to the first {...} block) before parsing.

Bug A (Write Invoice + History + Event + Audit): the audit CTE does
  `RETURNING id AS audit_id`, but the final SELECT reads `(SELECT id FROM audit)`
  -> "column \"id\" does not exist". Fix: read audit_id.

New workflow_history version + repoint activeVersionId (n8n DB-edit pattern),
with a round-trip self-check. Workflow active flag is left unchanged.
"""
import json, subprocess, sys, uuid, tempfile, os

WF_ID = "invoice-pipeline-v1"
PG = ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai"]

OLD_PARSE = "  const text = item.content?.[0]?.text || '{}';\n  ai = JSON.parse(text);"
NEW_PARSE = (
    "  let text = item.content?.[0]?.text || '{}';\n"
    "  text = text.trim().replace(/^```(?:json)?\\s*/i, '').replace(/```\\s*$/, '').trim();\n"
    "  try { ai = JSON.parse(text); }\n"
    "  catch (e2) { const m = text.match(/\\{[\\s\\S]*\\}/); ai = JSON.parse(m ? m[0] : text); }"
)
OLD_AUDIT = "(SELECT id FROM audit)     AS audit_id"
NEW_AUDIT = "(SELECT audit_id FROM audit) AS audit_id"


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

    fixed = {"B": False, "A": False}
    for n in nodes:
        if n["name"] == "Build OutcomeObject + Idem Key":
            code = n["parameters"]["jsCode"]
            if NEW_PARSE in code:
                sys.exit("ABORT: outcome fix already applied")
            if OLD_PARSE not in code:
                sys.exit("ABORT: expected parse block not found in OutcomeObject — node changed?")
            n["parameters"]["jsCode"] = code.replace(OLD_PARSE, NEW_PARSE)
            fixed["B"] = True
        if n["name"] == "Write Invoice + History + Event + Audit":
            q = n["parameters"]["query"]
            if NEW_AUDIT in q:
                sys.exit("ABORT: audit fix already applied")
            if OLD_AUDIT not in q:
                sys.exit("ABORT: expected audit SELECT not found in Write node — node changed?")
            n["parameters"]["query"] = q.replace(OLD_AUDIT, NEW_AUDIT)
            fixed["A"] = True
    if not all(fixed.values()):
        sys.exit(f"ABORT: did not apply both fixes: {fixed}")
    print(f"applied fixes: {fixed}")

    new_vid = str(uuid.uuid4())
    nd = tempfile.mkdtemp()
    npath, cpath = os.path.join(nd, "nodes.json"), os.path.join(nd, "conns.json")
    json.dump(nodes, open(npath, "w")); json.dump(conns, open(cpath, "w"))
    subprocess.run(["docker", "cp", npath, "homeai-postgres:/tmp/p2f_nodes.json"], check=True)
    subprocess.run(["docker", "cp", cpath, "homeai-postgres:/tmp/p2f_conns.json"], check=True)

    authors = (meta.get("authors") or "").replace("'", "''")
    name = (meta.get("name") or WF_ID).replace("'", "''")
    desc = (meta.get("description") or "").replace("'", "''")
    sql = f"""
\\set nodes `cat /tmp/p2f_nodes.json`
\\set conns `cat /tmp/p2f_conns.json`
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
        "'has_fence_strip',(select exists(select 1 from json_array_elements((select nodes::json from workflow_history where \"versionId\"='" + new_vid + "')) e where e->>'name'='Build OutcomeObject + Idem Key' and (e->'parameters'->>'jsCode') like '%catch (e2)%')),"
        "'audit_fixed',(select exists(select 1 from json_array_elements((select nodes::json from workflow_history where \"versionId\"='" + new_vid + "')) e where e->>'name'='Write Invoice + History + Event + Audit' and (e->'parameters'->>'query') like '%SELECT audit_id FROM audit%'))"
        ");", tA=True))
    print(json.dumps(chk, indent=1))
    ok = chk["active_vid"] == new_vid and chk["audit_fixed"] is True and chk["has_fence_strip"] is True
    print(f"\nnew version: {new_vid}")
    print("SELF-CHECK:", "PASS ✅" if ok else "FAIL ❌")
    print(f"(previous version {active_vid} retained for rollback)")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
