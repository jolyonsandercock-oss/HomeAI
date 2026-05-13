# AI Schemas

Versioned JSON Schemas — one per AI worker. Used to constrain AI output via:
- **Ollama**: `format: <schema>` parameter on `/api/generate` (constrained generation since v0.5)
- **Anthropic**: `tools=[{name, description, input_schema}]` + `tool_choice={type:'tool',name}`

Eliminates "parse JSON from AI response" Code nodes and hallucinated field names.

Full implementation: SPEC.md §7.3. Added in U38 (2026-05-13).

## Schemas

| File | Worker | Used by |
|---|---|---|
| `email-classifier.schema.json` | email classifier | Gmail Ingest (Ollama + Haiku escalation) |
| `invoice-extract.schema.json` | invoice extractor | Invoice Pipeline P2 (Haiku), u36-invoice-haiku-fallback.sh |
| `nanny-classify.schema.json` | nanny classifier | Nanny P8 (Haiku) |
| `report-parser.schema.json` | report parser | Report Ingestion P9 (Haiku) |
| `dreaming-proposals.schema.json` | dreaming summariser | u36-dreaming-nightly.sh (Sonnet) |
| `reconciliation-explainer.schema.json` | reconciliation explainer | u36-reconciliation-explainer.sh (Sonnet) |
| `cornwall-news.schema.json` | news summariser | Cornwall News Briefing (Ollama) |

## OutcomeObject envelope (all schemas)

Every schema includes these top-level fields:

- `status`: `'success' | 'escalate' | 'fail'`
- `confidence`: number 0-1
- `reasoning`: short string
- `worker`: string (the worker name)
- `tier_used`: `'hot' | 'medium' | 'heavy' | 'haiku' | 'sonnet' | 'opus'`
- `requires_human`: boolean

Per-worker fields nest under `data` or live at top level depending on schema.

## schema_version

Each AI worker INSERT into `audit_log` includes `schema_version = '<file>@<git_sha_7>'`
(e.g. `email-classifier.schema.json@dc22278`). Lets us track which workers are on
which schema generation. Added in V44 migration.

## Updating a schema

1. Edit the JSON file. Bump nothing — `schema_version` derives from the file content + git sha at the time of commit.
2. Commit. The next pipeline run picks up the new schema and writes the new `schema_version`.
3. For backwards-compat queries, `audit_log.ai_parsed` is JSONB — extra fields are tolerated by downstream consumers.
