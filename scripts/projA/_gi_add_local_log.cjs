// One-shot: add a parallel "Log ai_usage (local)" node to the Gmail Ingest
// Pipeline export so the qwen email-classify call is logged to ai_usage.
const fs = require('fs');
const p = '/tmp/gi.json';
const d = JSON.parse(fs.readFileSync(p, 'utf8'));
const wf = Array.isArray(d) ? d[0] : d;
if (wf.nodes.find(n => n.name === 'Log ai_usage (local)')) { console.log('already present'); process.exit(0); }
const base = wf.nodes.find(n => n.name === 'Log ai_usage');
const local = JSON.parse(JSON.stringify(base));
local.name = 'Log ai_usage (local)';
local.id = 'log-aiusage-local-1';
local.position = [2000, 600];
local.onError = 'continueRegularOutput';
local.parameters = JSON.parse(JSON.stringify(base.parameters));
local.parameters.query = `-- local qwen email classify (PROVIDER_v1)
INSERT INTO ai_usage
  (timestamp, trace_id, task_type, model_used, tier, escalated,
   prompt_tokens, completion_tokens, latency_ms, provider, realm, capability_tag, service)
VALUES (NOW(),
  COALESCE(NULLIF('{{ $('Sanitise Email').first().json.trace_id || '' }}', '')::uuid, gen_random_uuid()),
  'email_classifier', 'qwen2.5:7b', 'hot', false,
  COALESCE(({{ $('Classify Email (Ollama)').first().json.prompt_eval_count || 0 }})::int, 0),
  COALESCE(({{ $('Classify Email (Ollama)').first().json.eval_count || 0 }})::int, 0),
  0, 'ollama', 'owner', 'CAP_EMAIL_CLASSIFY', 'gmail-ingest')
RETURNING id;`;
wf.nodes.push(local);
const c = wf.connections['Parse Ollama Response'];
c.main[0].push({ node: 'Log ai_usage (local)', type: 'main', index: 0 });
fs.writeFileSync(p, JSON.stringify(wf, null, 2));
console.log('added node + connection. Parse Ollama Response ->', c.main[0].map(x => x.node).join(', '));
