#!/usr/bin/env python3
"""
p2-fix-complete-event.py — Bug C: P2's success path never marks the triggering
invoice.detected event as processed. Confirmed: invoices(source=email_ocr)=1 (the
first-ever successful extraction, today's test), while all 230 'processed'
invoice.detected events are no-attachment skips. Without this, every successful
extraction leaves its trigger event in 'processing' -> stale recovery re-claims
it -> re-runs P2 (re-burning Haiku $) indefinitely once invoice.detected is
re-admitted to the claim.

Fix: add a data-modifying CTE `done_evt` to the Write node that marks the trigger
event processed. Postgres runs data-modifying WITH terms exactly once regardless
of reference, but we also expose it in the final SELECT for visibility.

New workflow_history version + repoint activeVersionId, with self-check.
Workflow active flag unchanged.
"""
import json, subprocess, sys, uuid, tempfile, os

WF_ID = "invoice-pipeline-v1"
PG = ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai"]

ANCHOR = ("  RETURNING id AS audit_id\n"
          ")\n"
          "SELECT (SELECT id FROM new_inv)   AS invoice_id,")
REPLACEMENT = ("  RETURNING id AS audit_id\n"
               "),\n"
               "done_evt AS (\n"
               "  UPDATE events SET status='processed', processed_at=NOW(),\n"
               "         error_message='invoice_extracted'\n"
               "   WHERE id = {{ $json.event_id }} AND status IN ('processing','pending')\n"
               "  RETURNING id\n"
               ")\n"
               "SELECT (SELECT id FROM new_inv)   AS invoice_id,\n"
               "       (SELECT id FROM done_evt)  AS completed_event_id,")


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
        if n["name"] == "Write Invoice + History + Event + Audit":
            q = n["parameters"]["query"]
            if "done_evt AS" in q:
                sys.exit("ABORT: complete-event fix already applied")
            if ANCHOR not in q:
                sys.exit("ABORT: anchor not found in Write node — did the audit-id fix run first?")
            n["parameters"]["query"] = q.replace(ANCHOR, REPLACEMENT)
            done = True
    if not done:
        sys.exit("ABORT: Write node not found")
    print("applied Bug C fix (done_evt CTE)")

    new_vid = str(uuid.uuid4())
    nd = tempfile.mkdtemp()
    npath, cpath = os.path.join(nd, "nodes.json"), os.path.join(nd, "conns.json")
    json.dump(nodes, open(npath, "w")); json.dump(conns, open(cpath, "w"))
    subprocess.run(["docker", "cp", npath, "homeai-postgres:/tmp/p2c_nodes.json"], check=True)
    subprocess.run(["docker", "cp", cpath, "homeai-postgres:/tmp/p2c_conns.json"], check=True)

    authors = (meta.get("authors") or "").replace("'", "''")
    name = (meta.get("name") or WF_ID).replace("'", "''")
    desc = (meta.get("description") or "").replace("'", "''")
    sql = f"""
\\set nodes `cat /tmp/p2c_nodes.json`
\\set conns `cat /tmp/p2c_conns.json`
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
        "'has_done_evt',(select exists(select 1 from json_array_elements((select nodes::json from workflow_history where \"versionId\"='" + new_vid + "')) e where e->>'name'='Write Invoice + History + Event + Audit' and (e->'parameters'->>'query') like '%done_evt AS%'))"
        ");", tA=True))
    print(json.dumps(chk, indent=1))
    ok = chk["active_vid"] == new_vid and chk["has_done_evt"] is True
    print(f"\nnew version: {new_vid}")
    print("SELF-CHECK:", "PASS ✅" if ok else "FAIL ❌")
    print(f"(previous version {active_vid} retained for rollback)")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
