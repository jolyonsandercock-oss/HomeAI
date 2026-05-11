#!/bin/bash
# /home_ai/scripts/schema-drift-check.sh
# Detect schema drift between the running database and the migration history.
#
# Strategy: dump the live schema with pg_dump --schema-only, then dump the
# expected schema by piping init-db.sql + every V*__*.sql migration through
# a throwaway Postgres in a sibling container. Diff the two normalized dumps.
#
# Anything that's drifted (manual ALTER TABLEs, hand-crafted indexes, etc)
# shows up. Output goes to /home_ai/backups/schema-drift-<DATE>.diff and
# the script exits 0 if no drift, 1 if drift found (so cron + alerting can
# pick it up).
#
# Usage:
#   bash /home_ai/scripts/schema-drift-check.sh             # one-off
#   30 5 * * 0 /home_ai/scripts/schema-drift-check.sh \
#     >> /home_ai/backups/schema-drift.log 2>&1              # weekly cron

set -euo pipefail

OUT_DIR="/home_ai/backups"
DATE=$(date +%Y%m%d-%H%M)
LIVE="$OUT_DIR/schema-live-$DATE.sql"
EXPECTED="$OUT_DIR/schema-expected-$DATE.sql"
DIFF_OUT="$OUT_DIR/schema-drift-$DATE.diff"

# ── 1. Dump live schema ─────────────────────────────────────────
echo "→ dumping live schema"
docker exec homeai-postgres pg_dump -U postgres -d homeai \
  --schema-only --no-owner --no-acl --no-comments \
  > "$LIVE"

# ── 2. Build expected schema in throwaway Postgres ─────────────
TEMP_NAME="schema-drift-tmp-$$"
echo "→ spinning up throwaway postgres ($TEMP_NAME)"

docker run -d --rm \
  --name "$TEMP_NAME" \
  --network home_ai_ai-internal \
  -e POSTGRES_PASSWORD=tmp \
  -e POSTGRES_DB=homeai \
  postgres:16 >/dev/null

cleanup() {
  docker rm -f "$TEMP_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Wait for tmp postgres
until docker exec "$TEMP_NAME" pg_isready -U postgres >/dev/null 2>&1; do
  sleep 1
done

# Apply init-db, then RLS, then seed-data, then each migration in order.
echo "→ applying init-db.sql + V2..V<N> in order"
docker exec -i "$TEMP_NAME" psql -U postgres -d homeai -v ON_ERROR_STOP=0 \
  < /home_ai/postgres/init-db.sql >/dev/null 2>&1 || true
docker exec -i "$TEMP_NAME" psql -U postgres -d homeai -v ON_ERROR_STOP=0 \
  < /home_ai/postgres/rls-policies.sql >/dev/null 2>&1 || true
docker exec -i "$TEMP_NAME" psql -U postgres -d homeai -v ON_ERROR_STOP=0 \
  < /home_ai/postgres/seed-data.sql >/dev/null 2>&1 || true

for mig in $(ls /home_ai/postgres/migrations/V*__*.sql | sort -V); do
  echo "  applying $(basename "$mig")"
  docker exec -i "$TEMP_NAME" psql -U postgres -d homeai -v ON_ERROR_STOP=0 \
    < "$mig" >/dev/null 2>&1 || true
done

echo "→ dumping expected schema"
docker exec "$TEMP_NAME" pg_dump -U postgres -d homeai \
  --schema-only --no-owner --no-acl --no-comments \
  > "$EXPECTED"

# ── 3. Normalise + diff ────────────────────────────────────────
# Use a POSITIVE allowlist: only keep lines that reference tables we
# actually declared in init-db.sql or the V*__*.sql migrations. n8n,
# Mastra, and any other vendor tables fall through.
#
# Build the allowlist by greping CREATE TABLE statements out of our SQL.
ALLOW_TABLES=$(grep -hoE 'CREATE TABLE (IF NOT EXISTS )?[a-z_][a-z_0-9]*' \
                 /home_ai/postgres/init-db.sql \
                 /home_ai/postgres/migrations/V*__*.sql 2>/dev/null \
               | awk '{print $NF}' | sort -u | paste -sd '|' -)

# Plus the known system catalogs we want to keep for sanity
ALLOW_RX="^(${ALLOW_TABLES}|events|events_overflow)\$"

normalise() {
  # Two-pass: first split the dump into per-statement chunks (semicolons
  # terminate statements), then keep ONLY chunks whose target table is in
  # our allowlist. Dynamically-created `events_YYYY_MM` partitions and
  # auto-generated FK constraint names are normalised away.
  python3 - "$1" "$ALLOW_TABLES" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
allow = set(sys.argv[2].split('|'))
allow.update({"events", "events_overflow"})

# Split on `;` followed by newline (rough but works for pg_dump output)
chunks = re.split(r';\s*\n', src)
out = []
for c in chunks:
    # Strip SET / -- / blank-only chunks
    body = "\n".join(l for l in c.splitlines() if l.strip() and not l.startswith("SET ") and not l.startswith("--"))
    if not body.strip():
        continue
    # Drop dynamically-created event partitions
    if re.search(r'events_\d{4}_\d{2}\b', body):
        continue
    # Find the public.<name> token this statement targets
    m = re.search(r'\b(?:TABLE|INDEX|VIEW|FUNCTION|SEQUENCE|TYPE|TRIGGER)\s+(?:IF\s+NOT\s+EXISTS\s+|ONLY\s+|CONCURRENTLY\s+)*"?(public\.)?"?([A-Za-z_][A-Za-z0-9_]*)', body)
    if not m:
        continue
    name = m.group(2)
    if name not in allow:
        continue
    # Normalise: strip trailing whitespace per-line, sort statements alphabetically
    body = "\n".join(l.rstrip() for l in body.splitlines())
    # Strip auto-generated suffixes like _01234567 on index/constraint names
    body = re.sub(r'_[0-9a-f]{8,}\b', '', body)
    out.append(body.strip())
out.sort()
print("\n;\n".join(out))
PY
}

normalise "$LIVE"     > "${LIVE}.norm"
normalise "$EXPECTED" > "${EXPECTED}.norm"

if diff -u "${EXPECTED}.norm" "${LIVE}.norm" > "$DIFF_OUT"; then
  echo "✓ no drift — live schema matches init-db + migrations"
  rm -f "$LIVE" "$EXPECTED" "$LIVE.norm" "$EXPECTED.norm" "$DIFF_OUT"
  exit 0
else
  LINES=$(wc -l < "$DIFF_OUT")
  echo "⚠ DRIFT detected — $LINES diff lines"
  echo "  full diff: $DIFF_OUT"
  echo "  live:      $LIVE"
  echo "  expected:  $EXPECTED"
  echo
  echo "── first 40 lines of drift ──"
  head -40 "$DIFF_OUT"
  exit 1
fi
