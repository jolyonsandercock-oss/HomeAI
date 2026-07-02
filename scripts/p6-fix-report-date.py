#!/usr/bin/env python3
"""
p6-fix-report-date.py — P6 fix #2 (after the regex repair let executions reach
the INSERT): "Insert accommodation_daily" fails with
  invalid input syntax for type date: "01 Jul"
because the parse node forwards the subject-line date verbatim ("01 Jul", no
year) and the INSERT interpolates it into a date column. Null would break the
same way ('' literal), so the parse node now ALWAYS emits an ISO date:
normalise "DD Mon" with the year inferred from received_at (with a >180-day
year-boundary guard), and default to the received date — the email is a daily
"for today" report. New workflow_history version + repoint, with self-check.
"""
import json, subprocess, sys, uuid, tempfile, os

WF_ID = "caterbook-pipeline-v1"
PG = ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai"]
NODE = "Parse Accommodation Report"

OLD_BLOCK = """} else {
  // Try to get from the subject
  const subjDate = ($json.subject || '').match(/for\\s+(\\d{1,2}\\s+\\w{3})/i);
  if (subjDate) reportDate = subjDate[1];
}"""

NEW_BLOCK = """} else {
  // Try to get from the subject
  const subjDate = ($json.subject || '').match(/for\\s+(\\d{1,2}\\s+\\w{3})/i);
  if (subjDate) reportDate = subjDate[1];
}

// Normalise to ISO — the INSERT interpolates report_date into a date column,
// so "01 Jul" (subject format, no year) or null both break it. Default = the
// email's received date: this is a daily "for today" report.
const baseDate = $json.received_at ? new Date($json.received_at) : new Date();
if (reportDate && !/^\\d{4}-\\d{2}-\\d{2}$/.test(reportDate)) {
  const d = new Date(reportDate + ' ' + baseDate.getFullYear());
  if (!isNaN(d)) {
    if (d - baseDate > 15552000000) d.setFullYear(d.getFullYear() - 1); // >180d ahead = year boundary
    reportDate = d.toISOString().slice(0, 10);
  } else {
    reportDate = null;
  }
}
if (!reportDate) reportDate = baseDate.toISOString().slice(0, 10);"""


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
            if "Normalise to ISO" in code:
                sys.exit("ABORT: already patched")
            if OLD_BLOCK not in code:
                sys.exit("ABORT: expected subject-date block not found")
            n["parameters"]["jsCode"] = code.replace(OLD_BLOCK, NEW_BLOCK)
            done = True
    if not done:
        sys.exit("ABORT: node not found")
    print("applied report_date normalisation")

    new_vid = str(uuid.uuid4())
    nd = tempfile.mkdtemp()
    npath, cpath = os.path.join(nd, "nodes.json"), os.path.join(nd, "conns.json")
    json.dump(nodes, open(npath, "w")); json.dump(conns, open(cpath, "w"))
    subprocess.run(["docker", "cp", npath, "homeai-postgres:/tmp/p6d_nodes.json"], check=True)
    subprocess.run(["docker", "cp", cpath, "homeai-postgres:/tmp/p6d_conns.json"], check=True)

    authors = (meta.get("authors") or "").replace("'", "''")
    name = (meta.get("name") or WF_ID).replace("'", "''")
    desc = (meta.get("description") or "").replace("'", "''")
    sql = f"""
\\set nodes `cat /tmp/p6d_nodes.json`
\\set conns `cat /tmp/p6d_conns.json`
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
    ok = chk_vid == new_vid and "Normalise to ISO" in code_now
    print(f"\nnew version: {new_vid}")
    print("SELF-CHECK:", "PASS ✅" if ok else "FAIL ❌")
    print(f"(previous version {active_vid} retained for rollback)")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
