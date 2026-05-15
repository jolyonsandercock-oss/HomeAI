#!/usr/bin/env bash
# u86-audit-schema-drift.sh — diff live DB schema vs migration replay schema.
# Read-only against live; creates throwaway DB for replay.
# Output: audits/<date>-schema-drift.md

set -euo pipefail
OUT=/home_ai/audits/$(date +%Y-%m-%d)-schema-drift.md
mkdir -p "$(dirname "$OUT")"

SCRATCH_DB="homeai_drift_$(date +%s)"
LIVE_DUMP=/tmp/live-schema.sql
REPLAY_DUMP=/tmp/replay-schema.sql

cleanup() {
    docker exec homeai-postgres dropdb -U postgres --if-exists "$SCRATCH_DB" 2>/dev/null || true
    rm -f "$LIVE_DUMP" "$REPLAY_DUMP"
}
trap cleanup EXIT

# 1. Dump live schema (filtered: skip extensions/owner/grants noise)
echo "→ dumping live schema..."
docker exec homeai-postgres pg_dump -U postgres -s --no-owner --no-acl homeai 2>/dev/null \
    | grep -v -E '^--|^SET |^SELECT pg_catalog|^CREATE EXTENSION|^COMMENT ON EXTENSION' \
    | sed '/^$/N;/^\n$/D' > "$LIVE_DUMP"

# 2. Create scratch DB + replay migrations
echo "→ creating scratch DB + replaying migrations..."
docker exec homeai-postgres createdb -U postgres "$SCRATCH_DB"
# Run init script first (if present), then migrations in V-order
INIT=/home_ai/postgres/init-db.sql
if [[ -f "$INIT" ]]; then
    docker exec -i homeai-postgres psql -U postgres -d "$SCRATCH_DB" < "$INIT" 2>&1 | tail -2 || true
fi
for f in /home_ai/postgres/migrations/V*.sql; do
    docker exec -i homeai-postgres psql -U postgres -d "$SCRATCH_DB" -v ON_ERROR_STOP=1 < "$f" 2>&1 | tail -2 || echo "  (failed: $f — continuing)"
done

# 3. Dump replay schema
echo "→ dumping replay schema..."
docker exec homeai-postgres pg_dump -U postgres -s --no-owner --no-acl "$SCRATCH_DB" 2>/dev/null \
    | grep -v -E '^--|^SET |^SELECT pg_catalog|^CREATE EXTENSION|^COMMENT ON EXTENSION' \
    | sed '/^$/N;/^\n$/D' > "$REPLAY_DUMP"

# 4. Diff
echo "→ diffing..."
DIFF=$(diff -u "$REPLAY_DUMP" "$LIVE_DUMP" || true)

{
echo "# Schema drift audit"
echo ""
echo "Generated $(date -Iseconds). Read-only against live; scratch DB ${SCRATCH_DB} created and dropped."
echo ""
echo "Compares live schema vs replay of postgres/init-db.sql + migrations/V*.sql."
echo ""
echo "- Lines starting with \`-\` (and not \`---\`): present in MIGRATIONS but NOT in live (migration not applied / table dropped manually)."
echo "- Lines starting with \`+\` (and not \`+++\`): present in LIVE but NOT in migrations (manual ALTER / drift)."
echo ""
if [[ -z "$DIFF" ]]; then
    echo "## Result: ✓ no drift detected"
else
    echo "## Result: ⚠ drift detected"
    echo ""
    echo '```diff'
    echo "$DIFF" | head -300
    echo '```'
    echo ""
    echo "Full diff truncated to 300 lines. Re-run with no limit if needed."
fi
} > "$OUT"
echo "✓ wrote $OUT"
