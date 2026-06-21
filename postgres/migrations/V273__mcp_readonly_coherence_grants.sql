-- V273: let the MCP server (connects as homeai_readonly) read the observability +
-- coherence layer. The MCP query tool has no schema whitelist — the block was
-- homeai_readonly lacking USAGE on ops/cognition. This completes Pillar 1 (MCP-native
-- live state) so BOTH agents read facts the same way.
GRANT USAGE ON SCHEMA ops, cognition TO homeai_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA ops, cognition TO homeai_readonly;
GRANT EXECUTE ON FUNCTION ops.live_state() TO homeai_readonly;
GRANT EXECUTE ON FUNCTION cognition.log_finding(text,text,text,text,boolean,text,bigint) TO homeai_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA ops, cognition GRANT SELECT ON TABLES TO homeai_readonly;
