# Home AI MCP server

Exposes Home AI's whitelisted database queries + read-only SQL via Model Context Protocol, so Claude Desktop / Claude Code / any MCP client can interrogate the system with the same realm-aware row-level security as the bot-responder.

## Endpoints

- **HTTP+SSE** (default): `http://localhost:8765/sse` — reach from Claude Desktop on Jo's Mac via Tailscale.
- **stdio**: set `MCP_TRANSPORT=stdio` for sessions where the agent spawns the server directly.

## Tools

| Tool | What it does |
|---|---|
| `list_slugs()` | Dump every active slug in `query_whitelist` with description + params |
| `run_slug(slug, params)` | Execute a slug with bound params |
| `query_postgres_readonly(sql)` | Ad-hoc SELECT/WITH/EXPLAIN — write keywords blocked, results capped at 50 rows / 10kB |

## Resources

- `homeai://today` — current `v_today_kpis_work` snapshot
- `homeai://properties` — full property portfolio

## Adding to Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json` on Jo's Mac (over Tailscale):

```json
{
  "mcpServers": {
    "homeai": {
      "type": "sse",
      "url": "http://home-ai.tail-xxxxx.ts.net:8765/sse"
    }
  }
}
```

Restart Claude Desktop. The Home AI tools appear in the tool palette.

## Adding to Claude Code

Already wired via `/home_ai/.mcp.json` — any Claude Code session run from `/home_ai/` picks up the server automatically. Tools are exposed as `mcp__homeai__list_slugs`, `mcp__homeai__run_slug`, etc.

## Retrofit history

This server is the standard-protocol shell over the bespoke slug system originally built for the bot-responder (U66). The bot-responder still uses direct slug-call (lower latency, in-process). MCP is the surface for *external* AI clients to read Home AI state with the same realm-aware safety.
