#!/usr/bin/env python3
"""
build_gmail_ingest_workflow.py — generate gmail-ingest.json for n8n.

Polling adapter for Pipeline 1. Polls Gmail every 15 min, parses + sanitises,
signs the payload, INSERTs a single email.received event. Master Router
routes email.received to gmail-ingest-v1 (the Email Pipeline) which handles
idempotency, classification, emails-table write, and audit_log.

Build rules respected:
  - No n8n credential store for app secrets — Vault fetched via HTTP nodes
    using the existing vault-token-header httpHeaderAuth credential.
  - SET LOCAL app.current_entity inserted before any RLS-protected write.
  - HMAC-SHA256 signing of event payload before INSERT to events.

n8n quirk worked around: the Postgres node v2.5 splits options.queryReplacement
on commas, which breaks for values containing commas (email bodies). To dodge
this we build the full SQL string in a Code node and execute it with no
positional parameters.

WORKFLOW_ID env var: re-uses an existing n8n workflow id when set (so the n8n
import command updates in place rather than creating a new row).
"""

import json
import os
import secrets
import string
import uuid
from pathlib import Path

OUTPUT = Path("/home_ai/.claude/n8n-exports/gmail-ingest.json")

# Stable IDs from live n8n (verified earlier in this session)
CRED_PG = {"id": "iTuuNfsqHY49MGhk", "name": "HomeAI Postgres"}
CRED_VAULT_HDR = {"id": "0wPA4DCDuehPC9Mf", "name": "vault-token-header"}

VAULT_URL = "http://vault:8200/v1/secret/data"
GMAIL_API = "https://gmail.googleapis.com/gmail/v1/users/me"


def nid() -> str:
    return str(uuid.uuid4())


nodes = []

# 1. Trigger
n_schedule = {
    "id": nid(), "name": "Every 15 Minutes",
    "type": "n8n-nodes-base.scheduleTrigger", "typeVersion": 1.2,
    "position": [240, 300],
    "parameters": {"rule": {"interval": [{"field": "minutes", "minutesInterval": 15}]}},
}
nodes.append(n_schedule)

# 2. Vault: gmail creds
n_vault_gmail = {
    "id": nid(), "name": "Vault: Gmail Creds",
    "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.2,
    "position": [460, 200],
    "credentials": {"httpHeaderAuth": CRED_VAULT_HDR},
    "parameters": {
        "url": f"{VAULT_URL}/gmail/account1",
        "authentication": "predefinedCredentialType",
        "nodeCredentialType": "httpHeaderAuth",
        "options": {},
    },
}
nodes.append(n_vault_gmail)

# 3. Vault: signing key
n_vault_signing = {
    "id": nid(), "name": "Vault: Signing Key",
    "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.2,
    "position": [460, 400],
    "credentials": {"httpHeaderAuth": CRED_VAULT_HDR},
    "parameters": {
        "url": f"{VAULT_URL}/signing",
        "authentication": "predefinedCredentialType",
        "nodeCredentialType": "httpHeaderAuth",
        "options": {},
    },
}
nodes.append(n_vault_signing)

# 4. OAuth refresh — refresh_token → access_token
n_oauth = {
    "id": nid(), "name": "OAuth: Refresh Access Token",
    "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.2,
    "position": [680, 300],
    "parameters": {
        "method": "POST",
        "url": "https://oauth2.googleapis.com/token",
        "sendBody": True,
        "contentType": "form-urlencoded",
        "bodyParameters": {"parameters": [
            {"name": "grant_type", "value": "refresh_token"},
            {"name": "refresh_token",
             "value": "={{ $('Vault: Gmail Creds').item.json.data.data.refresh_token }}"},
            {"name": "client_id",
             "value": "={{ $('Vault: Gmail Creds').item.json.data.data.oauth_client_id }}"},
            {"name": "client_secret",
             "value": "={{ $('Vault: Gmail Creds').item.json.data.data.oauth_client_secret }}"},
        ]},
        "options": {},
    },
}
nodes.append(n_oauth)

# 5. List recent messages
n_list = {
    "id": nid(), "name": "Gmail: List Messages",
    "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.2,
    "position": [900, 300],
    "parameters": {
        "method": "GET",
        "url": f"{GMAIL_API}/messages",
        "sendQuery": True,
        "queryParameters": {"parameters": [
            {"name": "q", "value": "newer_than:1d"},
            {"name": "maxResults", "value": "50"},
        ]},
        "sendHeaders": True,
        "headerParameters": {"parameters": [
            {"name": "Authorization",
             "value": "=Bearer {{ $json.access_token }}"},
        ]},
        "options": {},
    },
}
nodes.append(n_list)

# 6. IF any messages
n_if_any = {
    "id": nid(), "name": "Any Messages?",
    "type": "n8n-nodes-base.if", "typeVersion": 2,
    "position": [1120, 300],
    "parameters": {"conditions": {"conditions": [{
        "id": nid(),
        "leftValue": "={{ ($json.messages || []).length }}",
        "rightValue": 0,
        "operator": {"type": "number", "operation": "gt"},
    }], "options": {}}},
}
nodes.append(n_if_any)

# 7. Split per message
n_split = {
    "id": nid(), "name": "Split Per Message",
    "type": "n8n-nodes-base.splitOut", "typeVersion": 1,
    "position": [1340, 240],
    "parameters": {"fieldToSplitOut": "messages", "options": {}},
}
nodes.append(n_split)

# 8. Get full message
n_get = {
    "id": nid(), "name": "Gmail: Get Message",
    "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.2,
    "position": [1560, 240],
    "parameters": {
        "method": "GET",
        "url": "={{ 'https://gmail.googleapis.com/gmail/v1/users/me/messages/' + $json.id + '?format=full' }}",
        "sendHeaders": True,
        "headerParameters": {"parameters": [
            {"name": "Authorization",
             "value": "=Bearer {{ $('OAuth: Refresh Access Token').item.json.access_token }}"},
        ]},
        "options": {},
    },
}
nodes.append(n_get)

# 9. Parse + sanitise
PARSE_JS = r"""
function sanitiseForPrompt(rawText) {
  if (!rawText || typeof rawText !== 'string') return '';
  let clean = rawText.replace(/<[^>]*>/g, ' ');
  const patterns = [
    /ignore\s+(all\s+)?previous\s+instructions?/gi,
    /forget\s+(all\s+)?instructions?/gi,
    /you\s+are\s+now\s+/gi,
    /new\s+instructions?:/gi,
    /system\s*:/gi,
    /\[INST\]/gi, /\[\/INST\]/gi,
    /<\|im_start\|>/gi, /<\|im_end\|>/gi,
    /###\s*instruction/gi,
    /act\s+as\s+/gi,
    /pretend\s+(you\s+are|to\s+be)\s+/gi,
    /override\s+(the\s+)?system/gi,
    /jailbreak/gi,
  ];
  patterns.forEach(p => { clean = clean.replace(p, '[REDACTED]'); });
  clean = clean.substring(0, 2000);
  return clean.replace(/\s+/g, ' ').trim();
}
function decodeBase64Url(s) {
  if (!s) return '';
  return Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8');
}
function findTextPart(p) {
  if (!p) return '';
  if (p.mimeType === 'text/plain' && p.body && p.body.data) return decodeBase64Url(p.body.data);
  if (p.parts && Array.isArray(p.parts)) {
    for (const x of p.parts) { const t = findTextPart(x); if (t) return t; }
  }
  if (p.mimeType === 'text/html' && p.body && p.body.data) return decodeBase64Url(p.body.data);
  return '';
}
function header(hs, name) {
  if (!hs) return null;
  const h = hs.find(x => x.name && x.name.toLowerCase() === name.toLowerCase());
  return h ? h.value : null;
}

const msg = $json;
const payload = msg.payload || {};
const headers = payload.headers || [];
const fromRaw = header(headers, 'From') || '';
const subject = header(headers, 'Subject') || '';
const dateHdr = header(headers, 'Date');
const internalDate = msg.internalDate ? new Date(parseInt(msg.internalDate, 10)).toISOString() : null;
const receivedAt = internalDate || (dateHdr ? new Date(dateHdr).toISOString() : new Date().toISOString());

let fromName = null;
let fromAddress = fromRaw;
const m = fromRaw.match(/^\s*"?([^"<]*?)"?\s*<([^>]+)>\s*$/);
if (m) { fromName = m[1].trim() || null; fromAddress = m[2].trim(); }

const bodyText = findTextPart(payload);
const bodyTextSafe = sanitiseForPrompt(bodyText);
const hasAttachment = !!(payload.parts && payload.parts.some(p => p.filename && p.filename.length > 0));

return [{ json: {
  gmail_message_id: msg.id,
  account: 'account1',
  from_address: fromAddress,
  from_name: fromName,
  subject,
  body_text: bodyText,
  body_text_safe: bodyTextSafe,
  received_at: receivedAt,
  has_attachment: hasAttachment,
} }];
"""

n_parse = {
    "id": nid(), "name": "Parse + Sanitise",
    "type": "n8n-nodes-base.code", "typeVersion": 2,
    "position": [1780, 240],
    "parameters": {"language": "javaScript", "jsCode": PARSE_JS},
}
nodes.append(n_parse)

# 10. Build SQL — HMAC sign + escape values + assemble single events INSERT.
# Output is { sql } and the Postgres node executes it raw via expression.
BUILD_SQL_JS = r"""
const hmacKey = $('Vault: Signing Key').item.json.data.data.payload_hmac_key;
const parsed = $json;

const eventPayload = {
  gmail_message_id: parsed.gmail_message_id,
  account: parsed.account,
  from_address: parsed.from_address,
  from_name: parsed.from_name,
  subject: parsed.subject,
  body_text: parsed.body_text,
  body_text_safe: parsed.body_text_safe,
  received_at: parsed.received_at,
  has_attachment: parsed.has_attachment,
};
const canonical = JSON.stringify(eventPayload, Object.keys(eventPayload).sort());
const crypto = require('crypto');
const signature = crypto.createHmac('sha256', hmacKey).update(canonical).digest('hex');

function S(v) {
  if (v === null || v === undefined) return 'NULL';
  if (typeof v === 'boolean' || typeof v === 'number') return String(v);
  return "'" + String(v).replace(/'/g, "''") + "'";
}
function J(obj) {
  return "'" + JSON.stringify(obj).replace(/'/g, "''") + "'::jsonb";
}

const sql = `
SET LOCAL app.current_entity = 'all';

INSERT INTO events (
  event_type, source, entity_id, payload, payload_signature,
  idempotency_key, pipeline_version
) VALUES (
  'email.received', 'gmail', NULL, ${J(eventPayload)}, ${S(signature)},
  ${S('email_' + parsed.gmail_message_id)}, ${S('gmail_ingest:1.0')}
)
RETURNING id, trace_id;
`;

return [{ json: { sql, gmail_message_id: parsed.gmail_message_id } }];
"""

n_build_sql = {
    "id": nid(), "name": "Sign + Build Event SQL",
    "type": "n8n-nodes-base.code", "typeVersion": 2,
    "position": [2000, 240],
    "parameters": {"language": "javaScript", "jsCode": BUILD_SQL_JS},
}
nodes.append(n_build_sql)

# 11. Single events INSERT
n_persist = {
    "id": nid(), "name": "INSERT email.received",
    "type": "n8n-nodes-base.postgres", "typeVersion": 2.5,
    "position": [2220, 240],
    "credentials": {"postgres": CRED_PG},
    "parameters": {
        "operation": "executeQuery",
        "query": "={{ $json.sql }}",
        "options": {},
    },
}
nodes.append(n_persist)

n_no_messages = {
    "id": nid(), "name": "No Messages",
    "type": "n8n-nodes-base.noOp", "typeVersion": 1,
    "position": [1340, 420], "parameters": {},
}
nodes.append(n_no_messages)


def out(name):
    return {"node": name, "type": "main", "index": 0}


connections = {
    n_schedule["name"]:      {"main": [[out(n_vault_gmail["name"])]]},
    n_vault_gmail["name"]:   {"main": [[out(n_vault_signing["name"])]]},
    n_vault_signing["name"]: {"main": [[out(n_oauth["name"])]]},
    n_oauth["name"]:         {"main": [[out(n_list["name"])]]},
    n_list["name"]:          {"main": [[out(n_if_any["name"])]]},
    n_if_any["name"]:        {"main": [
        [out(n_split["name"])],
        [out(n_no_messages["name"])],
    ]},
    n_split["name"]:         {"main": [[out(n_get["name"])]]},
    n_get["name"]:           {"main": [[out(n_parse["name"])]]},
    n_parse["name"]:         {"main": [[out(n_build_sql["name"])]]},
    n_build_sql["name"]:     {"main": [[out(n_persist["name"])]]},
}

_alphabet = string.ascii_letters + string.digits
_workflow_id = os.environ.get("WORKFLOW_ID") or ''.join(
    secrets.choice(_alphabet) for _ in range(16)
)
workflow = {
    "id": _workflow_id,
    "name": "Gmail Ingest",
    "active": False,
    "isArchived": False,
    "nodes": nodes,
    "connections": connections,
    "settings": {"executionOrder": "v1"},
    "staticData": None,
    "meta": None,
    "pinData": None,
    "tags": [],
}

OUTPUT.parent.mkdir(parents=True, exist_ok=True)
OUTPUT.write_text(json.dumps(workflow, indent=2))
print(f"wrote {OUTPUT} ({len(nodes)} nodes)")
