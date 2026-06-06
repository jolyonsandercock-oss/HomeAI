#!/bin/bash
# /home_ai/scripts/u36-dreaming-nightly.sh
#
# Local Dreaming Workflow H — Phase 2 flagship (SPEC §7.2).
#
# Mines audit_log for AI worker failure/regression patterns over the last 24h.
# Sonnet summarises into 0-5 proposed heuristics, stored in dreaming_heuristics.
# A heuristics.md is rebuilt from all 'accepted' rows for Master Router to load.
#
# Cron: 0 2 * * *  (daily 02:00)

set -uo pipefail
HOURS_BACK="${1:-24}"
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" -e HOURS_BACK="$HOURS_BACK" homeai-bot-responder python << 'PYEOF'
import os, json, urllib.request, asyncio, asyncpg
from datetime import datetime
import anthropic

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN      = os.environ["PG_DSN"]
HOURS_BACK  = int(os.environ.get("HOURS_BACK", "24"))
MODEL       = "claude-sonnet-4-6"   # Sonnet — needs nuanced pattern judgement


def vault_get(p):
    r = urllib.request.Request(f"http://vault:8200/v1/secret/data/{p}",
                                headers={"X-Vault-Token": VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(r, timeout=5).read())["data"]["data"]


# U38: schema-constrained tool use.
SYSTEM_BLOCKS = [{
    "type": "text",
    "text": (
        "You are the Dreaming agent for a small-business automation engine. Each night you "
        "look at audit_log patterns from the last 24h — AI worker calls (email classifiers, "
        "invoice parsers, etc) and their outcomes — and propose prompt-engineering heuristics "
        "that the Master Router should incorporate. Your job is to spot SIGNAL not noise. "
        "Output 0-5 proposals — empty list is fine when there's no clear pattern. "
        "Each proposal must:\n"
        "  - Be specific (name the worker, the failure shape, the suggested rule).\n"
        "  - Be actionable: 'suggested_rule' should be a sentence the system can inject into a prompt.\n"
        "  - Have severity reflecting blast radius: 'high' if a pipeline is fully broken, "
        "    'medium' if degraded, 'low' for an optimisation.\n"
        "Already-accepted heuristics are provided so you don't repeat them.\n"
        "Call the record_proposals tool — never produce free text."
    ),
    "cache_control": {"type": "ephemeral"},
}]

PROPOSALS_TOOL = {
    "name": "record_proposals",
    "description": "Record 0-5 prompt-engineering heuristic proposals derived from audit_log patterns.",
    "input_schema": {
        "type": "object",
        "properties": {
            "proposals": {
                "type": "array",
                "maxItems": 5,
                "items": {
                    "type": "object",
                    "properties": {
                        "scope":          {"type": "string"},
                        "ai_worker":      {"type": ["string", "null"]},
                        "observation":    {"type": "string", "maxLength": 1000},
                        "suggested_rule": {"type": "string", "maxLength": 1000},
                        "severity":       {"type": "string", "enum": ["low", "medium", "high"]}
                    },
                    "required": ["scope", "observation", "suggested_rule", "severity"]
                }
            }
        },
        "required": ["proposals"]
    }
}
SCHEMA_VERSION = "dreaming-proposals.schema.json@U38"


async def main():
    api_key = vault_get("anthropic")["api_key"]
    client  = anthropic.Anthropic(api_key=api_key, max_retries=8, timeout=120)
    conn = await asyncpg.connect(PG_DSN)
    # R6: Dreaming mines cross-realm patterns in audit_log → OWNER scope.
    await conn.execute("SET app.current_realm = 'owner'")
    started = datetime.now()
    run_row = await conn.fetchrow("""
      INSERT INTO dreaming_runs (audit_window_h) VALUES ($1) RETURNING id
    """, HOURS_BACK)
    run_id = run_row["id"]

    # ── Mine patterns ──
    # 1. Worker × action counts (signal: high error rates)
    patterns = await conn.fetch(f"""
      SELECT pipeline, action, ai_worker, ai_model, COUNT(*) AS n,
             AVG((ai_parsed->>'confidence_score')::numeric) AS avg_conf
        FROM audit_log
       WHERE created_at >= now() - interval '{HOURS_BACK} hours'
         AND ai_worker IS NOT NULL
       GROUP BY 1,2,3,4
       ORDER BY n DESC LIMIT 30
    """)
    # 2. Failure-shaped actions (unparseable / error / escalation)
    failures = await conn.fetch(f"""
      SELECT pipeline, ai_worker, action, ai_model, COUNT(*) AS n,
             MIN(created_at) AS first_seen, MAX(created_at) AS last_seen
        FROM audit_log
       WHERE created_at >= now() - interval '{HOURS_BACK} hours'
         AND (action ILIKE '%unparseable%' OR action ILIKE '%error%' OR action ILIKE '%escalat%' OR action ILIKE '%reject%')
       GROUP BY 1,2,3,4
       ORDER BY n DESC LIMIT 20
    """)
    # 3. Already-accepted heuristics (so Sonnet doesn't repropose)
    accepted = await conn.fetch("""
      SELECT scope, ai_worker, suggested_rule
        FROM dreaming_heuristics
       WHERE status='accepted'
       ORDER BY generated_at DESC LIMIT 30
    """)

    payload = {
        "window_hours": HOURS_BACK,
        "worker_actions": [dict(r) for r in patterns],
        "failures": [dict(r) for r in failures],
        "already_accepted": [dict(r) for r in accepted],
    }
    def to_json(v):
        if hasattr(v, "isoformat"): return v.isoformat()
        if hasattr(v, "to_eng_string"): return str(v)
        return v
    payload_str = json.dumps(payload, default=to_json, indent=2)
    print(f"patterns={len(patterns)}  failures={len(failures)}  already={len(accepted)}")

    if not failures and not patterns:
        print("nothing to dream about")
        await conn.execute("""
          UPDATE dreaming_runs SET finished_at=now(), patterns_found=0, proposals_new=0
           WHERE id=$1
        """, run_id)
        await conn.close()
        return

    resp = client.messages.create(
        model=MODEL,
        max_tokens=2000,
        system=SYSTEM_BLOCKS,
        tools=[PROPOSALS_TOOL],
        tool_choice={"type": "tool", "name": "record_proposals"},
        messages=[{"role": "user", "content": "Today's audit-log mining:\n\n" + payload_str}],
    )
    in_tok = resp.usage.input_tokens
    out_tok = resp.usage.output_tokens
    cache_hits = getattr(resp.usage, "cache_read_input_tokens", 0) or 0

    # Tool-use response — guaranteed schema-valid.
    tool_uses = [b for b in resp.content if b.type == "tool_use"]
    if not tool_uses:
        print("no tool_use block returned")
        await conn.execute("""
          UPDATE dreaming_runs SET finished_at=now(), error_message=$2 WHERE id=$1
        """, run_id, "no tool_use in response")
        await conn.close()
        return
    decoded = tool_uses[0].input

    proposals = decoded.get("proposals", [])
    inserted = 0
    for p in proposals:
        await conn.execute("""
          INSERT INTO dreaming_heuristics
            (scope, ai_worker, observation, suggested_rule, severity, status, raw_pattern)
          VALUES ($1, $2, $3, $4, $5, 'proposed', $6)
        """, p.get("scope","unknown"), p.get("ai_worker"),
             p.get("observation","")[:1000], p.get("suggested_rule","")[:1000],
             p.get("severity","low"), json.dumps(p))
        inserted += 1

    # Rebuild heuristics.md from accepted heuristics
    accepted_full = await conn.fetch("""
      SELECT scope, ai_worker, observation, suggested_rule, severity
        FROM dreaming_heuristics WHERE status='accepted'
       ORDER BY severity DESC, generated_at DESC
    """)
    md = ["# Home AI — Accepted Dreaming Heuristics", "",
          f"Generated {datetime.now().isoformat()} from {len(accepted_full)} accepted heuristics.",
          "", "The Master Router loads this file at the start of each batch run.", ""]
    for h in accepted_full:
        md.append(f"## [{h['severity'].upper()}] {h['scope']}"
                  + (f" · {h['ai_worker']}" if h['ai_worker'] else ""))
        md.append(f"**Observation:** {h['observation']}")
        md.append(f"**Rule:** {h['suggested_rule']}")
        md.append("")
    md_text = "\n".join(md)
    # Write to /home_ai/storage/dreaming/heuristics.md — bot-responder doesn't have
    # access to that path. Write via a Postgres TEMP-style approach: leave it in the
    # container, let the host script ferry it out.
    with open("/tmp/heuristics.md", "w") as f:
        f.write(md_text)

    await conn.execute("""
      UPDATE dreaming_runs
         SET finished_at=now(), patterns_found=$2, proposals_new=$3,
             ai_input_tokens=$4, ai_output_tokens=$5, ai_cache_hits=$6
       WHERE id=$1
    """, run_id, len(patterns) + len(failures), inserted, in_tok, out_tok, cache_hits)

    # Log to ai_usage
    try:
        await conn.execute("""
          INSERT INTO ai_usage (task_type, model_used, tier, prompt_tokens, completion_tokens, cached, provider)
          VALUES ('dreaming', $1, 'cloud', $2, $3, $4, 'anthropic')
        """, MODEL, in_tok, out_tok, cache_hits > 0)
    except Exception:
        pass

    print(f"proposals={inserted}  in_tok={in_tok} (cached={cache_hits})  out_tok={out_tok}")

    await conn.close()

asyncio.run(main())
PYEOF

# Ferry heuristics.md from container to host
mkdir -p /home_ai/storage/dreaming
docker cp homeai-bot-responder:/tmp/heuristics.md /home_ai/storage/dreaming/heuristics.md 2>/dev/null || true
docker exec homeai-bot-responder rm -f /tmp/heuristics.md 2>/dev/null || true

# Telegram digest if any medium/high proposals
PROPOSALS=$(docker exec homeai-postgres psql -U postgres -d homeai -tA -c "
  SELECT COUNT(*) FROM dreaming_heuristics
   WHERE status='proposed' AND severity IN ('medium','high')
     AND generated_at > now() - interval '2 hours';" 2>/dev/null || echo 0)
if (( PROPOSALS > 0 )); then
  SUMMARY=$(docker exec homeai-postgres psql -U postgres -d homeai -tA -c "
    SELECT string_agg(format('  • [%s] %s: %s', severity, scope, LEFT(observation, 80)), E'\n')
      FROM dreaming_heuristics
     WHERE status='proposed' AND severity IN ('medium','high')
       AND generated_at > now() - interval '2 hours';" 2>/dev/null)
  bash /home_ai/.claude/scripts/notify-telegram.sh \
    "💭 <b>Dreaming proposals</b> — $PROPOSALS new (severity ≥ medium)
$SUMMARY

Review: SELECT * FROM dreaming_heuristics WHERE status='proposed' ORDER BY id DESC LIMIT 10;
Accept: UPDATE dreaming_heuristics SET status='accepted' WHERE id IN (...);" \
    "dreaming" >/dev/null 2>&1 || true
fi
