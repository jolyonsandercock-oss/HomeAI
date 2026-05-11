# Hook installation

Two PreToolUse hooks at `.claude/hooks/`:

| Hook | Enforces |
|---|---|
| `no-secrets-in-files.sh` | AGENTS.md "NEVER write any secret to a file" — blocks paths matching `*.env`, `*secret*`, `*credential*`, `*password*`, `*.pem`, `*.key`, and content containing live Vault/AWS/Anthropic keys. |
| `sql-rules.sh` | AGENTS.md "ALWAYS sign event payloads / SET LOCAL app.current_entity" — blocks `INSERT INTO events (...)` without `payload_signature` and `INSERT INTO <entity-scoped table>` without RLS context (`SET LOCAL`, `set_config`, or `SECURITY DEFINER`). |

Both are best-effort static analysis. They catch the obvious shape; they
won't catch every clever evasion. Hardening these to a complete enforcement
layer is a Phase 2 task.

## Install

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          { "type": "command", "command": "/home_ai/.claude/hooks/no-secrets-in-files.sh" },
          { "type": "command", "command": "/home_ai/.claude/hooks/sql-rules.sh" }
        ]
      }
    ]
  }
}
```

Reload Claude Code. Test with:
- Try to write a file at `/tmp/test.env` — should be blocked.
- Try to write `INSERT INTO events (event_type) VALUES ('x')` (no `payload_signature`) — should be blocked.

## Why opt-in

Installing project-level hooks at `~/.claude/settings.json` modifies your
Claude Code config — a destructive change Claude shouldn't auto-apply
without explicit ack. The scripts are tested and ready.

## Known limitations

- Static analysis only — multi-step constructions (e.g. dynamic SQL from JS)
  bypass the regex.
- Test files (`/tests/`, `/spec/`, `/examples/`, `/fixtures/`) are exempt
  from `sql-rules.sh` so the RLS test suite isn't blocked.
- Path-based content checks see the `new_string` for Edit, not the file's
  full state. So an Edit that doesn't include the SQL fragment but is
  applied to a file that has it elsewhere is allowed.
