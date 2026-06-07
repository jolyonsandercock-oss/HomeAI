#!/bin/bash
# check-dashboard-sql.sh — validate every static SQL query in build-dashboard
# against the LIVE schema, catching the /api/vehicles & audit_log class (stale
# columns / renamed tables) that syntax checks and the GET soak miss.
#
# Method: extract triple-quoted SQL from main.py; PREPARE each (real $N params,
# no value substitution) so Postgres parses+plans it. Fail ONLY on "does not
# exist" (a genuine schema mismatch). f-string-dynamic queries are skipped (can't
# validate without runtime values); param-type-inference errors are ignored.
# Echoes "ok" on success; lists the offending query + error and exits 1 on failure.
set -o pipefail
MAIN="/home_ai/services/build-dashboard/main.py"
SQLFILE="$(mktemp /tmp/dash-sql-XXXX.sql)"
trap 'rm -f "$SQLFILE"' EXIT

python3 - "$MAIN" > "$SQLFILE" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
SQL_START = re.compile(r'^\s*(SELECT|WITH|INSERT|UPDATE|DELETE)\b', re.I)
n = 0
for m in re.finditer(r'(?P<f>f?)(?P<q>"""|\'\'\')(?P<body>.*?)(?P=q)', src, re.DOTALL):
    body = m.group('body')
    if not SQL_START.match(body):
        continue
    if m.group('f') and ('{' in body):      # dynamic f-string — can't validate
        continue
    n += 1
    line = src[:m.start()].count('\n') + 1
    q = body.strip().rstrip(';')
    print(f"\\echo ::Q{n}@L{line}::")
    print(f"PREPARE _chk_{n} AS {q};")
PY

PGPW=$(grep '^POSTGRES_PASSWORD=' /home_ai/.env | cut -d= -f2-)
docker cp "$SQLFILE" homeai-postgres:/tmp/dash-sql-check.sql >/dev/null
out=$(docker exec -e PGPASSWORD="$PGPW" homeai-postgres \
       psql -U postgres -d homeai -v ON_ERROR_STOP=0 -q -f /tmp/dash-sql-check.sql 2>&1)
docker exec homeai-postgres rm -f /tmp/dash-sql-check.sql >/dev/null 2>&1

# Map each "does not exist" error back to its query marker.
bad=$(echo "$out" | awk '
  /::Q[0-9]+@L[0-9]+::/ { marker=$0 }
  /does not exist/      { print marker "  =>  " $0 }
')
if [[ -n "$bad" ]]; then
  echo "FAIL — dashboard queries referencing missing columns/tables:"
  echo "$bad"
  exit 1
fi
echo "ok"
