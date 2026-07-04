#!/usr/bin/env python3
"""
u293-gmail-sender-denylist.py — extend INVOICE_HEURISTIC_v1 in the Gmail Ingest
Pipeline's "Parse Ollama Response" node with a non-invoice SENDER denylist.

Why: the classifier (qwen2.5:7b) labels notification/system emails as 'invoice'
(verified 60d: Dext no-reply 212, Amazon shipment/order/auto-confirm 115, etc.),
each firing a full P2 run. The existing content heuristic downgrades payment-
failure/receipt bodies, but Amazon dispatch mails carry VAT/amounts that trip
its `looksLikeInvoice` guard, blocking the downgrade. This adds a sender
override that runs AFTER the content check and forces 'fyi' for senders that
have produced ZERO real invoices over 60 days (verified this session).

Surgical: single targeted string-insert into the node's jsCode (everything else
byte-identical). New workflow_history version + activeVersionId repoint.
Rollback id printed.
"""
import json, subprocess, sys, uuid, tempfile, os

WF_ID = "gmail-ingest-v1"
NODE_NAME = "Parse Ollama Response"
PG = ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai"]
MARKER = "u293"

ANCHOR = """  if (looksLikeFailure && !looksLikeInvoice) {
    finalCategory = 'action-required';
  } else if (looksLikeReceipt && !looksLikeInvoice) {
    finalCategory = 'fyi';
  }
}"""

INSERT = """  if (looksLikeFailure && !looksLikeInvoice) {
    finalCategory = 'action-required';
  } else if (looksLikeReceipt && !looksLikeInvoice) {
    finalCategory = 'fyi';
  }
  // u293 (2026-07-04) NON-INVOICE SENDER DENYLIST — override AFTER the content
  // heuristic. Notification/system senders that never send Jo a payable invoice
  // (verified 0 real invoices over 60d). Amazon dispatch mails carry VAT/amounts
  // that defeat the content check above, so force 'fyi' by sender here.
  const _sender = String($('Sanitise Email').first().json.from_address || '').toLowerCase();
  const _senderDomain = _sender.split('@')[1] || '';
  const DENY_ADDR = new Set(['no-reply@notifications.app.dext.com','shipment-tracking@amazon.co.uk','order-update@amazon.co.uk','auto-confirm@amazon.co.uk','payments-update@amazon.co.uk','no-reply@amazon.co.uk','return@amazon.co.uk','marketplace-messages@amazon.co.uk','automated@airbnb.com','express@airbnb.com','community@airbnb.com','accounts@gohenry.com']);
  const DENY_DOMAIN = new Set(['notifications.app.dext.com','healthchecks.io','mathacademy.com']);
  if (DENY_ADDR.has(_sender) || DENY_DOMAIN.has(_senderDomain)) {
    finalCategory = 'fyi';
  }
}"""


def psql(sql, tA=False):
    r = subprocess.run(PG + (["-tA"] if tA else []) + ["-c", sql], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"psql failed:\n{r.stderr}\n{r.stdout}")
    return r.stdout.strip()


def main():
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
        if n["name"] == NODE_NAME:
            code = n["parameters"]["jsCode"]
            if MARKER in code:
                sys.exit("ABORT: already patched (u293 marker present)")
            if code.count(ANCHOR) != 1:
                sys.exit(f"ABORT: anchor found {code.count(ANCHOR)}x (expected 1) — node changed?")
            n["parameters"]["jsCode"] = code.replace(ANCHOR, INSERT)
            done = True
    if not done:
        sys.exit(f"ABORT: node {NODE_NAME!r} not found")
    print("inserted sender denylist after the content heuristic")

    new_vid = str(uuid.uuid4())
    nd = tempfile.mkdtemp()
    npath, cpath = os.path.join(nd, "nodes.json"), os.path.join(nd, "conns.json")
    json.dump(nodes, open(npath, "w")); json.dump(conns, open(cpath, "w"))
    subprocess.run(["docker", "cp", npath, "homeai-postgres:/tmp/u293_nodes.json"], check=True)
    subprocess.run(["docker", "cp", cpath, "homeai-postgres:/tmp/u293_conns.json"], check=True)

    authors = (meta.get("authors") or "u293").replace("'", "''")
    name = (meta.get("name") or WF_ID).replace("'", "''")
    desc = (meta.get("description") or "").replace("'", "''")
    sql = f"""
\\set nodes `cat /tmp/u293_nodes.json`
\\set conns `cat /tmp/u293_conns.json`
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

    ok = psql(
        "select (nodes::text like '%u293%')::text from workflow_entity where id='" + WF_ID + "';", tA=True)
    print(f"new version: {new_vid}")
    print("SELF-CHECK marker present:", ok)
    print(f"rollback: UPDATE workflow_entity SET \"activeVersionId\"='{active_vid}' WHERE id='{WF_ID}';")
    sys.exit(0 if ok == "true" else 1)


if __name__ == "__main__":
    main()
