#!/usr/bin/env python3
"""u291-p2-binary-mode-fix.py — fix P2's vision extractor under filesystem binary mode.

ROOT CAUSE (found 2026-07-04): 'Build Extractor Prompt' read the attachment
as `$input.first().binary.data.data` — the raw field. That held inline
base64 only under n8n's legacy 'default' binary mode; under filesystem
binary mode (the default in newer n8n) the field holds the storage marker
string 'filesystem-v2'. That marker went into ollama's `images` array, and
Go's base64 decoder failed on the '-' at index 10:
    400 "illegal base64 data at input byte 10"
— every with-attachment P2 run died at 'Extract via Haiku', producing the
recurring invoice.detected dead-letter/stale-lease loop.

FIX: read the bytes via this.helpers.getBinaryDataBuffer() (mode-agnostic),
accepting either binary key ('data' from Extract Text passthrough, 'file'
from Decode + Build Form), with a loud error if the result still looks like
a marker.

Safety: new workflow_history row + activeVersionId repoint.
Rollback: UPDATE workflow_entity SET "activeVersionId"='<printed>' WHERE id='invoice-pipeline-v1'
"""

import json
import subprocess
import sys
import uuid

WORKFLOW_ID = 'invoice-pipeline-v1'
NODE_NAME = 'Build Extractor Prompt'
MARKER = 'u291: binary-mode-safe'

NEW_JS = r"""// u291: binary-mode-safe — read attachment bytes via the n8n helper so this
// works under BOTH binary storage modes. The old `bin.data.data` raw read
// returned the literal marker 'filesystem-v2' under filesystem mode, which
// went to ollama's images[] and 400'd ("illegal base64 data at input byte
// 10") on every with-attachment run.
const v = $('Decode + Build Form').first().json;
const bin = $input.first().binary || {};
const binKey = bin.data ? 'data' : (bin.file ? 'file' : null);
if (!binKey) throw new Error('u291: no binary property on input (expected data or file)');
const buf = await this.helpers.getBinaryDataBuffer(0, binKey);
const b64 = buf.toString('base64');
if (!b64 || b64.length < 100) {
  throw new Error(`u291: attachment binary suspiciously small (${b64.length} b64 chars) — binary mode marker leak?`);
}
const schema = "You are extracting structured data from an invoice IMAGE for accounting purposes. Extract only what is explicitly shown in the image. Do NOT infer or calculate. Return null for any missing field. Financial amounts must be numbers (not strings). Dates must be YYYY-MM-DD. Return ONLY valid JSON with keys: supplier_name (string), invoice_number (string), invoice_date (YYYY-MM-DD or null), due_date (YYYY-MM-DD or null), gross_amount (number), net_amount (number or null), vat_amount (number or null), currency (string, default GBP), category (string e.g. stock/utilities/services/other), confidence_score (number 0-1), requires_human (boolean), reasoning (string max 200 chars).";
const reqBody = {
  model: 'gemma4-doc', think: false, format: 'json', stream: false,
  options: { temperature: 0, num_predict: 512 },
  images: [b64],
  prompt: 'Filename: ' + (v.filename || '') + '. ' + schema
};
return [{ json: { ...v, image_b64: b64, content_hash: null, ollama_request: JSON.stringify(reqBody) } }];"""


def fetch_current():
    proc = subprocess.run(
        ['docker', 'exec', 'homeai-postgres', 'psql', '-U', 'postgres', '-d', 'homeai',
         '-tA', '-c', f"""SELECT row_to_json(t) FROM (
            SELECT "versionId" AS v, nodes::text AS nodes,
                   connections::text AS connections, name, authors
            FROM workflow_history
            WHERE "versionId" = (SELECT "activeVersionId" FROM workflow_entity WHERE id='{WORKFLOW_ID}')
         ) t;"""],
        check=True, capture_output=True, text=True,
    )
    data = json.loads(proc.stdout.strip())
    return {
        'current_version': data['v'],
        'nodes': json.loads(data['nodes']),
        'connections': json.loads(data['connections']),
        'name': data['name'],
        'authors': data['authors'],
    }


def patch_nodes(nodes):
    for n in nodes:
        if n.get('name') == NODE_NAME:
            params = n.setdefault('parameters', {})
            if MARKER in params.get('jsCode', ''):
                return False
            params['jsCode'] = NEW_JS
            return True
    raise RuntimeError(f"{NODE_NAME!r} not found in {WORKFLOW_ID}")


def install(current):
    new_uuid = str(uuid.uuid4())
    sql = f"""
BEGIN;
INSERT INTO workflow_history ("versionId", "workflowId", authors, nodes, connections, name, autosaved)
VALUES (
  '{new_uuid}',
  '{WORKFLOW_ID}',
  $authors${current['authors'] or 'u291'}$authors$,
  $nodes${json.dumps(current['nodes'])}$nodes$::json,
  $conns${json.dumps(current['connections'])}$conns$::json,
  $name${current['name']}$name$,
  false
);
UPDATE workflow_entity SET "activeVersionId"='{new_uuid}', "updatedAt"=NOW()
WHERE id='{WORKFLOW_ID}';
COMMIT;
"""
    subprocess.run(
        ['docker', 'exec', '-i', 'homeai-postgres', 'psql', '-U', 'postgres', '-d', 'homeai'],
        input=sql, check=True, capture_output=True, text=True,
    )
    print(f"patched. rollback: UPDATE workflow_entity SET \"activeVersionId\"='{current['current_version']}' WHERE id='{WORKFLOW_ID}';")


def main():
    current = fetch_current()
    if not patch_nodes(current['nodes']):
        print("already patched — no change")
        return
    install(current)


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as e:
        print(f'subprocess failed: {e}\nstderr: {e.stderr}', file=sys.stderr)
        sys.exit(1)
