#!/usr/bin/env python3
"""
u295-dynamic-denylist.py — make the gmail-ingest sender denylist DATA-DRIVEN.

Replaces u293's hardcoded DENY_ADDR/DENY_DOMAIN sets in "Parse Ollama Response"
with a read of static_context['invoice.sender_denylist'] (maintained by the
u294 derivation cron), and extends "Fetch AI Thresholds" to fetch it. The u293
seed remains embedded as a FALLBACK so a missing/empty key never regresses the
classifier to no-guard.

Two node edits, one workflow_history version + repoint. Rollback id printed.
"""
import json, subprocess, sys, uuid, tempfile, os

WF_ID = "gmail-ingest-v1"
PG = ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai"]
MARKER = "u295"

FETCH_OLD = "SELECT value FROM static_context WHERE key = 'ai.thresholds'"
FETCH_NEW = ("SELECT (SELECT value FROM static_context WHERE key='ai.thresholds') AS value, "
             "(SELECT value FROM static_context WHERE key='invoice.sender_denylist') AS denylist")

DENY_OLD = """  const DENY_ADDR = new Set(['no-reply@notifications.app.dext.com','shipment-tracking@amazon.co.uk','order-update@amazon.co.uk','auto-confirm@amazon.co.uk','payments-update@amazon.co.uk','no-reply@amazon.co.uk','return@amazon.co.uk','marketplace-messages@amazon.co.uk','automated@airbnb.com','express@airbnb.com','community@airbnb.com','accounts@gohenry.com']);
  const DENY_DOMAIN = new Set(['notifications.app.dext.com','healthchecks.io','mathacademy.com']);"""

DENY_NEW = """  // u295: denylist from static_context['invoice.sender_denylist'] (u294 cron).
  // Fallback = the u293 seed so a missing/empty key never drops the guard.
  const _SEED_ADDR = ['no-reply@notifications.app.dext.com','shipment-tracking@amazon.co.uk','order-update@amazon.co.uk','auto-confirm@amazon.co.uk','payments-update@amazon.co.uk','no-reply@amazon.co.uk','return@amazon.co.uk','marketplace-messages@amazon.co.uk','automated@airbnb.com','express@airbnb.com','community@airbnb.com','accounts@gohenry.com'];
  const _SEED_DOMAIN = ['notifications.app.dext.com','healthchecks.io','mathacademy.com'];
  let _dl = $('Fetch AI Thresholds').first().json.denylist;
  if (typeof _dl === 'string') { try { _dl = JSON.parse(_dl); } catch(e) { _dl = null; } }
  const DENY_ADDR = new Set((_dl && Array.isArray(_dl.addresses) && _dl.addresses.length) ? _dl.addresses : _SEED_ADDR);
  const DENY_DOMAIN = new Set((_dl && Array.isArray(_dl.domains)) ? _dl.domains : _SEED_DOMAIN);"""


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

    fetched = parsed = False
    for n in nodes:
        if n["name"] == "Fetch AI Thresholds":
            q = n["parameters"]["query"]
            if "invoice.sender_denylist" in q:
                sys.exit("ABORT: Fetch node already fetches denylist (u295 applied?)")
            if FETCH_OLD not in q:
                sys.exit(f"ABORT: Fetch query not as expected: {q!r}")
            n["parameters"]["query"] = q.replace(FETCH_OLD, FETCH_NEW)
            fetched = True
        if n["name"] == "Parse Ollama Response":
            c = n["parameters"]["jsCode"]
            if MARKER in c:
                sys.exit("ABORT: Parse already u295-patched")
            if c.count(DENY_OLD) != 1:
                sys.exit(f"ABORT: DENY block found {c.count(DENY_OLD)}x (expected 1) — node changed?")
            n["parameters"]["jsCode"] = c.replace(DENY_OLD, DENY_NEW)
            parsed = True
    if not (fetched and parsed):
        sys.exit(f"ABORT: fetched={fetched} parsed={parsed} — node(s) not found")
    print("patched Fetch AI Thresholds (query) + Parse Ollama Response (dynamic denylist)")

    new_vid = str(uuid.uuid4())
    nd = tempfile.mkdtemp()
    npath, cpath = os.path.join(nd, "nodes.json"), os.path.join(nd, "conns.json")
    json.dump(nodes, open(npath, "w")); json.dump(conns, open(cpath, "w"))
    subprocess.run(["docker", "cp", npath, "homeai-postgres:/tmp/u295_nodes.json"], check=True)
    subprocess.run(["docker", "cp", cpath, "homeai-postgres:/tmp/u295_conns.json"], check=True)
    authors = (meta.get("authors") or "u295").replace("'", "''")
    name = (meta.get("name") or WF_ID).replace("'", "''")
    desc = (meta.get("description") or "").replace("'", "''")
    sql = f"""
\\set nodes `cat /tmp/u295_nodes.json`
\\set conns `cat /tmp/u295_conns.json`
BEGIN;
INSERT INTO workflow_history ("versionId","workflowId",authors,"createdAt","updatedAt",
                              nodes,connections,name,autosaved,description)
VALUES ('{new_vid}','{WF_ID}','{authors}',now(),now(),
        :'nodes'::json, :'conns'::json, '{name}', false, '{desc}');
UPDATE workflow_entity SET nodes=:'nodes'::json, connections=:'conns'::json,
       "activeVersionId"='{new_vid}', "updatedAt"=now() WHERE id='{WF_ID}';
COMMIT;
"""
    r = subprocess.run(PG + ["-v", "ON_ERROR_STOP=1"], input=sql, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"DB write failed:\n{r.stderr}\n{r.stdout}")
    ok = psql("select (nodes::text like '%u295%' and nodes::text like '%invoice.sender_denylist%')::text "
              f"from workflow_entity where id='{WF_ID}';", tA=True)
    print(f"new version: {new_vid}")
    print("SELF-CHECK:", "PASS" if ok == "true" else "FAIL")
    print(f"rollback: UPDATE workflow_entity SET \"activeVersionId\"='{active_vid}' WHERE id='{WF_ID}';")
    sys.exit(0 if ok == "true" else 1)


if __name__ == "__main__":
    main()
